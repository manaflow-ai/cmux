import CmuxNextAgentActivity
import CmuxNextCompat
import Darwin
import Foundation
import Testing
@testable import CmuxNextComputerUse

/// The app's machine-consent connection to the legacy helper.
struct ComputerUseConsentHostTests {
    @MainActor @Test func theAttachIsAnAuthenticatedHostRequest() throws {
        let configuration = AgentActivitySocketSource.Configuration(socketPath: "/tmp/h.sock", authToken: "agent",
                                                                    hostAuthToken: "host", machineName: "")
        let line = ComputerUseConsentHost.attachLine(configuration)
        #expect(line.last == 0x0A)
        let object = try #require(try JSONSerialization.jsonObject(with: line) as? [String: Any])
        #expect(object["auth_token"] as? String == "agent")
        #expect(object["host_auth_token"] as? String == "host")
        let request = try #require(object["request"] as? [String: Any])
        #expect(request["method"] as? String == "machine_consent_host")
    }

    @Test func linesAreClassified() {
        #expect(ComputerUseConsentHost.classify(["ok": true, "result": ["attached": true]]) == .attached)
        #expect(ComputerUseConsentHost.classify(["ok": true, "result": [String: Any]()]) == .refusedAttach)
        #expect(ComputerUseConsentHost.classify(["ok": true]) == .refusedAttach)
        #expect(ComputerUseConsentHost.classify(["ok": false, "error": "unknown method"]) == .refusedAttach)
        #expect(ComputerUseConsentHost.classify(["type": "machine_consent", "id": 1]) == .question)
        #expect(ComputerUseConsentHost.classify(["type": "consent_refused", "surface": "screen"]) == .question)
        #expect(ComputerUseConsentHost.classify(["type": "event"]) == .other)
    }

    /// A build the helper cannot verify (ad hoc signed) is its own refusal, with the helper's
    /// reason; a host-token failure stays a plain refusal.
    @Test func anUnverifiedHostIsItsOwnRefusal() {
        let prefix = "Unauthorized host-only consent request"
        #expect(ComputerUseConsentHost.classify(["ok": false, "error": "\(prefix): host_unverified (not Apple-signed (ad hoc or unsigned))",
                                                 "exit_code": 77]) == .hostUnverified("not Apple-signed (ad hoc or unsigned)"))
        #expect(ComputerUseConsentHost.classify(["ok": false, "error": "\(prefix): host_unverified (signing identifier com.example.x is not a cmux app)"])
            == .hostUnverified("signing identifier com.example.x is not a cmux app"))
        #expect(ComputerUseConsentHost.classify(["ok": false, "error": "\(prefix): host_unverified"]) == .hostUnverified(""))
        #expect(ComputerUseConsentHost.classify(["ok": false, "error": prefix, "exit_code": 77]) == .refusedAttach)
        #expect(ComputerUseConsentHost.classify(["ok": true, "result": ["attached": true]]) == .attached)
    }

    // MARK: Over a socket

    /// Two questions get two daemon answers (nothing is cached), and no daemon answer is ok:false.
    @MainActor @Test(.timeLimit(.minutes(1))) func everyQuestionAsksTheDaemonAndAFailureFailsClosed() async throws {
        let helper = try FakeHelper()
        defer { helper.close() }
        let answers = Mutex<[Data?]>([Data(#"{"consent":"granted"}"#.utf8), Data(#"{"consent":"revoked"}"#.utf8), nil])
        let host = ComputerUseConsentHost(consent: { answers.withLock { $0.removeFirst() } }, refused: { _ in }, acceptsServer: nil)
        defer { host.stop() }
        host.start(helper.configuration)
        let peer = try #require(await helper.accept())
        defer { peer.close() }
        try await peer.attach()
        for (id, consent) in [(1, "granted"), (2, "revoked")] {
            peer.send(["type": "machine_consent", "id": id])
            let reply = try json(await peer.readLine())
            #expect(reply["id"] as? Int == id)
            #expect(reply["ok"] as? Bool == true)
            #expect((reply["result"] as? [String: Any])?["consent"] as? String == consent)
        }
        peer.send(["type": "machine_consent", "id": 3])
        let failed = try json(await peer.readLine())
        #expect(failed["id"] as? Int == 3)
        #expect(failed["ok"] as? Bool == false)
        #expect(answers.withLock { $0.isEmpty })
    }

    /// A helper that hangs up gets a new host connection, which answers.
    @MainActor @Test(.timeLimit(.minutes(1))) func aLostConnectionIsReplaced() async throws {
        let helper = try FakeHelper()
        defer { helper.close() }
        let host = ComputerUseConsentHost(consent: { Data(#"{"consent":"granted"}"#.utf8) }, refused: { _ in }, acceptsServer: nil)
        defer { host.stop() }
        host.start(helper.configuration)
        let first = try #require(await helper.accept())
        try await first.attach()
        first.close()
        let second = try #require(await helper.accept())
        defer { second.close() }
        try await second.attach()
        second.send(["type": "machine_consent", "id": 1])
        #expect(try json(await second.readLine())["ok"] as? Bool == true)
    }

    /// A query still with the daemon when the host stops writes nothing on the stopped connection.
    @MainActor @Test(.timeLimit(.minutes(1))) func aStoppedHostAnswersNothing() async throws {
        let helper = try FakeHelper()
        defer { helper.close() }
        let (asked, askedContinuation) = AsyncStream<Void>.makeStream()
        let (release, releaseContinuation) = AsyncStream<Void>.makeStream()
        let host = ComputerUseConsentHost(consent: {
            askedContinuation.yield()
            for await _ in release { break }
            return Data(#"{"consent":"granted"}"#.utf8)
        }, refused: { _ in }, acceptsServer: nil)
        host.start(helper.configuration)
        let peer = try #require(await helper.accept())
        defer { peer.close() }
        try await peer.attach()
        peer.send(["type": "machine_consent", "id": 1])
        for await _ in asked { break }
        host.stop()
        releaseContinuation.yield()
        #expect(await peer.readLine(timeout: 2_000) == nil)
    }

    /// An unverified host is logged and reported once with the helper's reason, and the host hangs up.
    /// When a later connection is accepted (the helper restarted and now verifies it), the report clears.
    /// (The daemon also clears it on every start; this covers an accept that comes later.)
    @MainActor @Test(.timeLimit(.minutes(1))) func anUnverifiedRefusalIsReportedAndClearsOnRecovery() async throws {
        let helper = try FakeHelper()
        defer { helper.close() }
        let (reasons, reasonContinuation) = AsyncStream<String?>.makeStream()
        let host = ComputerUseConsentHost(consent: { nil }, refused: { _ in }, unverified: { reasonContinuation.yield($0) },
                                          acceptsServer: nil)
        defer { host.stop() }
        host.start(helper.configuration)
        let peer = try #require(await helper.accept())
        defer { peer.close() }
        _ = try json(await peer.readLine())
        peer.send(["ok": false, "exit_code": 77,
                   "error": "Unauthorized host-only consent request: host_unverified (not signed by cmux's team)"])
        var reported: [String?] = []
        var retried: FakeHelperPeer?
        defer { retried?.close() }
        for await reason in reasons {
            reported.append(reason)
            guard reported.count == 1 else { break }
            #expect(await peer.readLine(timeout: 5_000) == nil)
            // A refused attach is not retried; the restarted helper starts the host again,
            // and this time it accepts it.
            host.start(helper.configuration)
            retried = try #require(await helper.accept())
            try await retried?.attach()
        }
        #expect(reported == ["not signed by cmux's team", nil])
    }
}

nonisolated private func json(_ line: Data?) throws -> [String: Any] {
    let line = try #require(line)
    return try #require(try JSONSerialization.jsonObject(with: line) as? [String: Any])
}

/// Runs blocking socket work off the cooperative pool.
nonisolated private func blocking<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async { continuation.resume(returning: body()) }
    }
}

/// A unix socket standing in for the legacy helper's `machine_consent_host` side.
nonisolated private final class FakeHelper: Sendable {
    let path: String
    private let listener: Int32

    init() throws {
        let path = NSTemporaryDirectory() + "consent-\(UUID().uuidString.prefix(8)).sock"
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        self.path = path
        self.listener = listener
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8.prefix(buffer.count - 1))
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard listener >= 0, bound == 0, listen(listener, 4) == 0 else { throw POSIXError(.EADDRNOTAVAIL) }
    }

    @MainActor var configuration: AgentActivitySocketSource.Configuration {
        .init(socketPath: path, authToken: "agent", hostAuthToken: "host", machineName: "")
    }

    /// The host's next connection, or nil after 10 s.
    func accept() async -> FakeHelperPeer? {
        let listener = listener
        let descriptor = await blocking { () -> Int32 in
            var poller = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            guard poll(&poller, 1, 10_000) == 1 else { return -1 }
            return Darwin.accept(listener, nil, nil)
        }
        return descriptor >= 0 ? FakeHelperPeer(descriptor) : nil
    }

    func close() {
        Darwin.close(listener)
        unlink(path)
    }
}

/// One host connection; used by one test at a time.
nonisolated private final class FakeHelperPeer: @unchecked Sendable { // crash-allow: one test drives it, one call at a time
    private let descriptor: Int32
    private var buffer = Data()

    init(_ descriptor: Int32) {
        self.descriptor = descriptor
        var one: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Reads the attach request and accepts it.
    func attach() async throws {
        let request = try json(await readLine())
        #expect((request["request"] as? [String: Any])?["method"] as? String == "machine_consent_host")
        #expect(request["host_auth_token"] as? String == "host")
        send(["ok": true, "result": ["attached": true]])
    }

    func send(_ object: [String: Any]) {
        var data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        data.append(0x0A)
        _ = data.withUnsafeBytes { Darwin.send(descriptor, $0.baseAddress, $0.count, 0) }
    }

    /// The next line, or nil when the host hung up or nothing came within `timeout` ms.
    func readLine(timeout: Int32 = 10_000) async -> Data? {
        await blocking { [self] in
            while true {
                if let newline = buffer.firstIndex(of: 0x0A) {
                    let line = Data(buffer[buffer.startIndex..<newline])
                    buffer.removeSubrange(buffer.startIndex...newline)
                    return line
                }
                var poller = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                guard poll(&poller, 1, timeout) == 1 else { return nil }
                var chunk = [UInt8](repeating: 0, count: 4096)
                let count = recv(descriptor, &chunk, chunk.count, 0)
                guard count > 0 else { return nil }
                buffer.append(contentsOf: chunk[0..<count])
            }
        }
    }

    func close() {
        Darwin.close(descriptor)
    }
}
