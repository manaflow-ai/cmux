import Foundation
import Testing
@testable import CmuxMobileTransport

/// A scripted carrier session: daemon streams that answer each request line, a session that
/// can end, and connect refusals.
final class FakeCarrierSession: CloudCarrierSession, @unchecked Sendable {
    private let lock = NSLock()
    private var live = false
    private(set) var connects = 0
    private(set) var streams = 0
    /// Refusals the next connects throw, in order.
    var connectErrors: [LinkError] = []

    func connect(deadlineMs: UInt32) async throws {
        try lock.withLock {
            connects += 1
            if !connectErrors.isEmpty { throw connectErrors.removeFirst() }
            live = true
        }
    }

    /// The next streams fail with this (a mux stream the daemon refused).
    var streamError: LinkError?

    func openStream() async throws -> any CloudCarrierByteStream {
        try lock.withLock {
            guard live else { throw LinkError(code: "closed", message: "no session") }
            if let streamError { throw streamError }
            streams += 1
        }
        return EchoLineStream()
    }

    func isConnected() async -> Bool { lock.withLock { live } }

    private var waiters: [CheckedContinuation<Void, Never>] = []

    func waitClosed() async {
        await withCheckedContinuation { continuation in
            let now = lock.withLock { () -> Bool in
                if !live { return true }
                waiters.append(continuation)
                return false
            }
            if now { continuation.resume() }
        }
    }

    func close() async { drop() }

    /// The relay dropped the session (the carrier's `waitClosed` resolves).
    func drop() {
        let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            live = false
            defer { waiters = [] }
            return waiters
        }
        for waiter in waiting { waiter.resume() }
    }
}

/// Answers each `{"id"}` line with `{"id","ok":true}`, split across two chunks.
final class EchoLineStream: CloudCarrierByteStream, @unchecked Sendable {
    private let continuation: AsyncStream<Data>.Continuation
    private var iterator: AsyncStream<Data>.AsyncIterator

    init() {
        let (inbox, continuation) = AsyncStream<Data>.makeStream()
        self.continuation = continuation
        iterator = inbox.makeAsyncIterator()
    }

    func send(_ data: Data) async throws {
        for line in data.split(separator: 0x0A) {
            guard let object = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any], let id = object["id"] as? String else { continue }
            let reply = Data(#"{"id":"\#(id)","ok":true,"data":{}}"#.utf8) + Data([0x0A])
            continuation.yield(reply.prefix(5))
            continuation.yield(reply.dropFirst(5))
        }
    }

    /// One reader at a time (the daemon client's read loop).
    func recv() async -> Data? {
        await iterator.next()
    }

    func close() async { continuation.finish() }
}

@Suite struct CloudCarrierLinkTests {
    let machine = "vm_aaaaaaaaaaaaaaaaaaaa"

    func link(_ session: FakeCarrierSession) -> CloudCarrierLink {
        CloudCarrierLink(machineID: machine, session: session)
    }

    /// Deny by default: a Cloud machine's carrier serves the daemon only. Every other service a
    /// Mac link serves is refused `unknown_service` without opening a stream.
    @Test func everyServiceButDaemonIsRefused() async throws {
        let session = FakeCarrierSession()
        try await session.connect(deadlineMs: 1)
        let link = link(session)
        for service in ["auth", "acpmux", "version", "file", "upload", "browser", "chief", "localhost", "echo", "home-inbox", "needs-you", ""] {
            await #expect(throws: LinkError.self) { _ = try await link.openChannel(service: service, args: [:]) }
            do {
                _ = try await link.openInputChannel(service: service, args: [:])
                Issue.record("\(service) opened on the input lane")
            } catch let error as LinkError {
                #expect(error.code == "unknown_service")
            }
        }
        #expect(session.streams == 0)
        let channel = try await link.openChannel(service: "daemon", args: [:])
        #expect(session.streams == 1)
        await channel.close(code: "eof", reason: "")
    }

    /// The daemon client reads the carrier's arbitrary byte splits as whole lines.
    @Test func daemonRequestsRoundTripOverTheCarrier() async throws {
        let session = FakeCarrierSession()
        try await session.connect(deadlineMs: 1)
        let channel = try await link(session).openChannel(service: "daemon", args: [:])
        let client = DaemonClient(channel: channel)
        let reply = try await client.request("identify")
        let object = try #require(try JSONSerialization.jsonObject(with: reply) as? [String: Any])
        #expect(object["ok"] as? Bool == true)
        await client.close()
    }

    /// A session that ended drops its link at once (the controller dials a new one and the
    /// coordinator binds the list and terminals again): it never reconnects under the same link,
    /// where they would stay on the dead session's channels.
    @Test func aDroppedSessionDropsTheLinkAndNeverRedialsInside() async throws {
        let session = FakeCarrierSession()
        try await session.connect(deadlineMs: 1)
        let link = link(session)
        var states = link.states.makeAsyncIterator()
        #expect(await states.next() == .connected(.cloudCarrier, .carrier, rttMillis: nil))
        session.drop()
        // The carrier's own end, before any heartbeat.
        #expect(await states.next() == .disconnected(reason: "the Cloud link dropped"))
        await #expect(throws: LinkError.self) { _ = try await link.ping() }
        do {
            _ = try await link.openChannel(service: "daemon", args: [:])
            Issue.record("a stream opened on a dead session")
        } catch let error as LinkError {
            #expect(error.code == "closed")
        }
        #expect(session.connects == 1, "no dial inside the link")
    }

    /// A mux stream the live session could not open (`transport`, from the carrier's
    /// `open_stream`) fails that channel with the carrier's code and leaves the link up; only a
    /// session that ended (`closed`) drops it.
    @Test func aMuxOpenFailureFailsTheChannelNotTheLink() async throws {
        let session = FakeCarrierSession()
        try await session.connect(deadlineMs: 1)
        session.streamError = LinkError(code: "transport", message: "stream: the daemon refused the mux stream")
        let link = link(session)
        do {
            _ = try await link.openChannel(service: "daemon", args: [:])
            Issue.record("a refused mux stream opened")
        } catch let error as LinkError {
            #expect(error.code == "transport")
        }
        #expect(try await link.ping() == 0, "the session is still up")
        session.streamError = nil
        _ = try await link.openChannel(service: "daemon", args: [:])
    }

    /// A dial whose caller gives up (the controller cancels it) closes its carrier session, so the
    /// carrier stops asking the platform for grants for a link nobody wants.
    @Test(.timeLimit(.minutes(1))) func aCancelledDialClosesItsSession() async throws {
        let session = HangingCarrierSession()
        let dialer = CloudCarrierDialer(makeSession: { _, _ in session })
        let endpoint = LinkEndpoint(baseURL: URL(fileURLWithPath: "/"), teamID: "t", deviceID: "d",
                                    macDeviceID: "vm_0123456789abcdefghij")
        let dial = Task { try await dialer.dial(endpoint, transport: .cloudCarrier, accessToken: "") }
        await session.started.wait()
        dial.cancel()
        _ = await dial.result
        #expect(await session.closed.isSet, "the cancelled dial closed its carrier")
    }

    /// The dialer: `vm_…` ids only; the first dial's refusals come back as the carrier said.
    @Test func dialerMapsRefusals() async throws {
        let session = FakeCarrierSession()
        let dialer = CloudCarrierDialer(makeSession: { _, _ in session })
        let endpoint = { (id: String) in LinkEndpoint(baseURL: URL(string: "https://x.test")!, teamID: "t", deviceID: "d", macDeviceID: id) }
        await #expect(throws: LinkError.self) { _ = try await dialer.dial(endpoint("mac-1"), transport: .cloudCarrier, accessToken: "t") }
        for code in [LinkError.unauthorized, "carrier.handshake", "cloud.machine.paused", "transport"] {
            session.connectErrors = [LinkError(code: code, message: code)]
            do {
                _ = try await dialer.dial(endpoint(machine), transport: .cloudCarrier, accessToken: "t")
                Issue.record("\(code) dialed")
            } catch let error as LinkError {
                #expect(error.code == code)
            }
        }
        let link = try await dialer.dial(endpoint(machine), transport: .cloudCarrier, accessToken: "t")
        #expect(link.transport == .cloudCarrier)
        #expect(link.connectedPath == .carrier)
    }

    /// Which refusals stop the redials (the coordinator shows why) and which retry.
    @Test func permanentRefusals() {
        #expect(CloudCarrierDialer.isPermanent(LinkError(code: "carrier.handshake", message: "")))
        #expect(CloudCarrierDialer.isPermanent(LinkError(code: "cloud.machine.paused", message: "")))
        #expect(CloudCarrierDialer.isPermanent(LinkError(code: "cloud.machine.not_found", message: "")))
        #expect(CloudCarrierDialer.isPermanent(LinkError(code: "auth.forbidden", message: "")))
        #expect(!CloudCarrierDialer.isPermanent(LinkError(code: LinkError.unauthorized, message: "")))
        #expect(!CloudCarrierDialer.isPermanent(LinkError(code: "transport", message: "")))
        #expect(!CloudCarrierDialer.isPermanent(LinkError(code: "timeout", message: "")))
        #expect(CloudCarrierDialer.isRetryable(LinkError(code: "transport", message: "")))
        #expect(!CloudCarrierDialer.isRetryable(LinkError(code: "carrier.handshake", message: "")))
        #expect(CloudCarrierDialer.isPermanent(LinkError(code: CloudCarrierDialer.noDaemonKey, message: "")))
        // A malformed answer is asked again; constructor arguments are not.
        #expect(CloudCarrierDialer.isRetryable(LinkError(code: CloudCarrierDialer.answerCode, message: "")))
        #expect(!CloudCarrierDialer.isPermanent(LinkError(code: CloudCarrierDialer.answerCode, message: "")))
        // A code the app doesn't know (an unlisted 4xx, a non-JSON body's "http", a failure the carrier
        // gave up on) is a refusal: no redial, so no grant asked for forever.
        #expect(CloudCarrierDialer.isPermanent(LinkError(code: "http", message: "")))
        #expect(CloudCarrierDialer.isPermanent(LinkError(code: "cloud.something_new", message: "")))
        #expect(CloudCarrierDialer.isPermanent(LinkError(code: "carrier.failed", message: "")))
        #expect(!CloudCarrierDialer.isRetryable(LinkError(code: "cloud.something_new", message: "")))
        #expect(CloudCarrierDialer.isRetryable(LinkError(code: "closed", message: "")))
        #expect(CloudCarrierDialer.isPermanent(LinkError(code: "invalid_argument", message: "")))
        #expect(CloudCarrierDialer.isRetryable(LinkError(code: CloudCarrierDialer.keychainLocked, message: "")))
        #expect(CloudCarrierDialer.isPermanent(LinkError(code: CloudCarrierDialer.keychainUnavailable, message: "")))
    }
}

/// A one-shot flag an async test can wait on.
actor TestLatch {
    private(set) var isSet = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func set() {
        isSet = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }

    func wait() async {
        if isSet { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

/// A carrier whose dial never answers on its own (a silent platform): it ends only when its
/// caller cancels it or it is closed, the way the Rust carrier's close cuts a dial short.
final class HangingCarrierSession: CloudCarrierSession, @unchecked Sendable {
    let started = TestLatch()
    let closed = TestLatch()

    func connect(deadlineMs: UInt32) async throws {
        await started.set()
        await closed.wait()
        throw LinkError(code: "closed", message: "closed while dialing")
    }

    func openStream() async throws -> any CloudCarrierByteStream { throw LinkError(code: "closed", message: "") }
    func isConnected() async -> Bool { false }
    func waitClosed() async {}
    func close() async { await closed.set() }
}
