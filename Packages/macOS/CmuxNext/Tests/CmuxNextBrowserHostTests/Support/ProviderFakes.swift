import CmuxNextBrowser
import CmuxNextBrowserAutomation
import CmuxNextWakeups
import Darwin
import Foundation
import Observation
@testable import CmuxNextBrowserHost

/// Two connected provider connections over a socketpair (app end, host end).
func connectedPair() -> (app: ProviderConnection, host: ProviderConnection) {
    var fds: [Int32] = [-1, -1]
    precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
    return (ProviderConnection(fd: fds[0]), ProviderConnection(fd: fds[1]))
}

/// Values from an async stream, read one at a time by a test on the main
/// actor (a pump task owns the stream's iterator).
@MainActor
final class MainQueue<Element: Sendable> {
    private var buffered: [Element] = []
    private var ended = false
    private var waiter: CheckedContinuation<Element?, Never>?
    private var pump: Task<Void, Never>?

    init(_ stream: AsyncStream<Element>) {
        pump = Task { [weak self] in
            for await value in stream { self?.deliver(value) }
            self?.finish()
        }
    }

    isolated deinit { pump?.cancel() }

    private func deliver(_ value: Element) {
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: value)
        } else {
            buffered.append(value)
        }
    }

    private func finish() {
        ended = true
        waiter?.resume(returning: nil)
        waiter = nil
    }

    func next() async -> Element? {
        if !buffered.isEmpty { return buffered.removeFirst() }
        if ended { return nil }
        return await withCheckedContinuation { waiter = $0 }
    }
}

/// The browser host's side of the link, as a test drives it.
@MainActor
final class FakeHost {
    let link: ProviderConnection
    private let frames: MainQueue<ProviderFrame>

    init(_ link: ProviderConnection) {
        self.link = link
        frames = MainQueue(link.frames)
        link.start()
    }

    func next() async -> ProviderFrame? { await frames.next() }

    func send(_ frame: ProviderFrame) { _ = try? link.send(frame) }

    /// One length-prefixed frame body sent as it is (malformed frames).
    func sendRaw(_ json: String) {
        var bytes = Data()
        withUnsafeBytes(of: UInt32(json.utf8.count).bigEndian) { bytes.append(contentsOf: $0) }
        bytes.append(contentsOf: json.utf8)
        link.sendEncoded(bytes)
    }

    func ack() { send(.helloAck(agentBundle: "agent();", agentBundleSHA: "sha1")) }
}

/// Hands the provider a fresh socketpair per dial and the host end to the
/// test (main actor, like the provider).
@MainActor
final class FakeDialer {
    private let continuation: AsyncStream<ProviderConnection>.Continuation
    private let hosts: MainQueue<ProviderConnection>
    private(set) var count = 0

    init() {
        let (stream, continuation) = AsyncStream.makeStream(of: ProviderConnection.self, bufferingPolicy: .bufferingOldest(16))
        self.continuation = continuation
        hosts = MainQueue(stream)
    }

    /// The host end of the next dial (one consumer: the test).
    func nextHost() async -> ProviderConnection? { await hosts.next() }

    func dial(_ credentials: ProviderCredentials) async throws -> ProviderConnection {
        count += 1
        let (app, host) = connectedPair()
        continuation.yield(host)
        return app
    }
}

final class FakeCredentials: ProviderCredentialsSource {
    /// The fake host runs in this process, so its peer pid is ours.
    var value: ProviderCredentials? = ProviderCredentials(socketPath: "/unused", secret: ProviderSecret("s3cret-value"), hostPID: getpid())
    func providerCredentials() async -> ProviderCredentials? { value }
}

@Observable
final class FakeTabs: ProviderTabSource {
    var providerTabs: [ProviderTab] = []
}

@Observable
final class FakeAccess: ProviderAccessSource {
    var table: [String: ProviderTabAccess] = [:]
    func access(forTab targetID: String) -> ProviderTabAccess {
        table[targetID] ?? ProviderTabAccess(extensionHostAccess: false, userOverride: false, extensions: [])
    }
}

final class FakeMarking: ProviderAgentMarking {
    var marked: [String] = []
    func agentWillDrive(targetID: String) { marked.append(targetID) }
}

final class FakeDriver: DriverCallHandler {
    let events: AsyncStream<DriverEvent>
    let emitter: AsyncStream<DriverEvent>.Continuation
    var answer: (String, DriverJSON) -> Result<DriverJSON, DriverError> = { _, _ in .success(.null) }

    init() { (events, emitter) = AsyncStream.makeStream(of: DriverEvent.self, bufferingPolicy: .bufferingOldest(64)) }

    func call(method: String, params: DriverJSON) async throws(DriverError) -> DriverJSON {
        try answer(method, params).get()
    }
}

final class FakeRelay: ProviderDevToolsRelay {
    var holdsPrepare = false
    var prepareResult = true
    private var held: [CheckedContinuation<Bool, Never>] = []
    var onMessage: ((String) -> Void)?
    var onEnd: (() -> Void)?
    var sent: [String] = []
    var stopped: [String] = []
    /// Answers each sent command from the "browser" with `{"id":raw,"result":{"ok":true}}`
    /// plus its sessionId; only commands whose method contains `echoOnly`, when set.
    var echoes = true
    var echoOnly: String?

    var prepared: [String] = []
    /// Every sent message, in order, for a test that waits for a send.
    let sentQueue: MainQueue<String>
    private let sentFeed: AsyncStream<String>.Continuation

    init() {
        let (stream, feed) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .bufferingOldest(64))
        sentFeed = feed
        sentQueue = MainQueue(stream)
    }

    func prepareRelay(targetID: String) async -> Bool {
        prepared.append(targetID)
        guard holdsPrepare else { return prepareResult }
        return await withCheckedContinuation { held.append($0) }
    }

    func releasePrepare(_ ready: Bool) {
        let waiting = held
        held = []
        waiting.forEach { $0.resume(returning: ready) }
    }

    func startRelay(targetID: String, onMessage: @escaping (String) -> Void, onEnd: @escaping () -> Void) -> Bool {
        self.onMessage = onMessage
        self.onEnd = onEnd
        return true
    }

    func send(targetID: String, message: String) -> CEFDevToolsRawSend {
        sent.append(message)
        sentFeed.yield(message)
        if echoes, echoOnly.map({ message.contains($0) }) ?? true, let id = CEFDevToolsRawMessage.topLevelID(in: message) {
            let session = message.contains(#""sessionId":"S""#) ? #","sessionId":"S""# : ""
            let reply = #"{"id":\#(id),"result":{"ok":true}\#(session)}"#
            Task { @MainActor [weak self] in self?.onMessage?(reply) }
        }
        return .sent
    }

    func stopRelay(targetID: String) { stopped.append(targetID) }
}

/// A provider wired to fakes, plus the fakes.
@MainActor
struct ProviderHarness {
    let clock = ManualClock()
    let dialer = FakeDialer()
    let credentials = FakeCredentials()
    let tabs = FakeTabs()
    let access = FakeAccess()
    let marking = FakeMarking()
    let driver = FakeDriver()
    let relay = FakeRelay()
    let provider: BrowserHostProvider

    init(tabs initial: [ProviderTab] = []) {
        tabs.providerTabs = initial
        let dialer = dialer
        provider = BrowserHostProvider(
            identity: ProviderIdentity(providerID: "cmux-app", installID: "inst_1"),
            credentials: credentials, tabs: tabs, access: access, driver: driver, relay: relay, marking: marking,
            clock: clock, backoff: Backoff(initial: .seconds(1), maximum: .seconds(1), jitter: 0),
            prepareDeadline: .seconds(8),
            dial: { try await dialer.dial($0) })
    }

    /// The next host end the provider dialed.
    func nextHost() async -> FakeHost? {
        guard let link = await dialer.nextHost() else { return nil }
        return FakeHost(link)
    }

    /// Starts the provider and returns the host after it read `hello` (and
    /// any frames that follow before the ack are left for the test).
    func connected() async -> (FakeHost, ProviderFrame?) {
        provider.start()
        let host = await nextHost()!
        let hello = await host.next()
        return (host, hello)
    }
}

func tab(_ id: String, _ engine: ProviderEngine, url: String = "https://a.test/", title: String = "A", visible: Bool = true) -> ProviderTab {
    ProviderTab(targetID: id, engine: engine, workspace: "ws_1", profile: "default", url: url, title: title, visible: visible)
}
