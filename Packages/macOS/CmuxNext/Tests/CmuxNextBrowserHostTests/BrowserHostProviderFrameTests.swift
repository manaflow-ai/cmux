import CmuxNextBrowser
import CmuxNextBrowserAutomation
@testable import CmuxNextBrowserHost
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Darwin
import Foundation
import Observation
import Testing

/// Review 2 of pl-main-bc (finding 6): 5474e1c445e handled each host frame on a display frame, so every
/// CDP command and driver call of an agent waited for a frame tick (up to the frame scheduler's 100 ms
/// stall timeout while the display sleeps); the review-1 fix handles each frame as it is read. The
/// provider dials a stand-in host here: a call's reply leaves with no display frame.
///
/// Each frame is one task of the automation class on the injected scheduler, so a
/// command read while the person's input is pending runs after that input; it runs on the next run
/// loop turn even while frames run. The tab list is read only in automation tasks, never in the
/// person's turn. Turns and frames fire by hand (the stall clock never moves): the tests await the
/// provider's post, a frame link request and the host's frames, never a wall clock.
@MainActor @Suite(.timeLimit(.minutes(1))) struct BrowserHostProviderFrameTests {
    @Test func aCallIsAnsweredWithoutADisplayFrame() async throws {
        let fixture = try ProviderFixture()
        try await fixture.connect()
        // A call that names no tab is refused by the app itself, at once (no driver, no page).
        await fixture.host.send(.call(id: 7, method: "cookies.get", params: .object([:])))
        await fixture.turns.runNext()
        try await fixture.expectRefusal(7)
        #expect(fixture.work.frames.frames == 0, "the reply waited for a display frame")
        await fixture.close()
    }

    /// While another client keeps the frame link up (terminal output, an animation), a call still
    /// runs on the next run loop turn: sequential request and reply never waits for vsync, or for the
    /// stall timeout while the window is hidden.
    @Test func aCallWhileFramesRunIsAnsweredWithoutADisplayFrame() async throws {
        let fixture = try ProviderFixture()
        let keeper = LinkKeeper(on: fixture.work)
        try await fixture.connect()
        await fixture.host.send(.call(id: 8, method: "cookies.get", params: .object([:])))
        await fixture.turns.runNext()
        try await fixture.expectRefusal(8)
        #expect(fixture.work.frames.frames == 0, "the reply waited for a display frame")
        keeper.stop()
        await fixture.close()
    }

    /// A command the host sends while a key is pending waits for the key: its turn holds it in the
    /// automation queue, and the frame after the input cleared runs it.
    @Test func aCommandQueuedDuringPendingInputRunsAfterIt() async throws {
        let fixture = try ProviderFixture()
        let keeper = LinkKeeper(on: fixture.work)
        try await fixture.connect()
        fixture.input.pending = true
        await fixture.host.send(.call(id: 9, method: "cookies.get", params: .object([:])))
        await fixture.turns.runNext()
        #expect(fixture.work.postedCount(.automation) == 1, "the call ran ahead of the person's pending key")
        fixture.input.pending = false
        fixture.clock.advance(ms: 17)
        fixture.work.frameDidFire(timestamp: 1, refreshInterval: 1.0 / 60)
        #expect(fixture.work.postedCount(.automation) == 0, "the input cleared: the call runs")
        try await fixture.expectRefusal(9)
        keeper.stop()
        await fixture.close()
    }

    /// The tab list walks every tab and may read extension manifests: a change the person caused is
    /// not read in their input response, and a burst of changes is read once, in an automation task
    /// held behind pending input (it asks for a frame), which then announces the tab.
    @Test func aTabChangeIsReadInAnAutomationTaskNotInThePersonsTurn() async throws {
        let fixture = try ProviderFixture()
        try await fixture.connect()
        let reads = fixture.sources.reads
        fixture.input.pending = true
        fixture.work.causes.withCause(.person) {
            fixture.sources.list.tabs = [ProviderTab(targetID: "tab-1", engine: .webkit, workspace: "w", profile: "p",
                                                     url: "https://example.com/", title: "Example", visible: true)]
        }
        fixture.sources.list.tabs[0].title = "Example, renamed"
        _ = fixture.work.causes.flushPersonCaused()
        #expect(fixture.sources.reads == reads, "the person's turn read the tab list")
        // The read task reaches main on the next run loop turn, holds behind the key, and asks for a frame.
        await fixture.links.next()
        #expect(fixture.sources.reads == reads, "the read ran ahead of the person's pending key")
        #expect(fixture.work.postedCount(.automation) == 1, "a burst of changes posts one read")
        fixture.input.pending = false
        fixture.clock.advance(ms: 17)
        fixture.work.frameDidFire(timestamp: 1, refreshInterval: 1.0 / 60)
        #expect(fixture.sources.reads == reads + 1)
        let announced = try await fixture.host.next { if case .event("tab.announced", _) = $0 { true } else { false } }
        guard case .event(_, .object(let fields)) = announced else { return }
        #expect(fields["targetId"] == .string("tab-1"))
        #expect(fields["title"] == .string("Example, renamed"))
        await fixture.close()
    }

    /// Each handled frame kind has its own owner on the board and a task; frames the app ignores have
    /// neither, so they post nothing.
    @Test func eachHandledFrameKindHasABrowserHostTask() {
        let handled: [(ProviderFrame, String)] = [
            (.call(id: 1, method: "tab.info", params: .null), "browser-host.call"),
            (.cdpAttach(targetID: "t"), "browser-host.cdp.attach"),
            (.cdpDetach(targetID: "t"), "browser-host.cdp.detach"),
            (.cdp(targetID: "t", message: "{}"), "browser-host.cdp"),
            (.lease(targetID: "t", lease: nil), "browser-host.lease"),
            (.input(event: .null), "browser-host.input"),
        ]
        for (frame, owner) in handled { #expect(BrowserHostProvider.task(for: frame)?.owner == owner) }
        #expect(BrowserHostProvider.task(for: .unknown(tag: "from-a-newer-host")) == nil)
        #expect(BrowserHostProvider.task(for: .helloAck(agentBundle: "", agentBundleSHA: "")) == nil)
    }
}

/// A provider on an injected scheduler (fake link, fake input, a clock and run loop turns the test
/// moves), dialing a stand-in host.
@MainActor
final class ProviderFixture {
    let clock: TestUptime
    let input: FakeInput
    let turns: HeldTurns
    let links: LinkRequests
    let work: MainWorkScheduler
    let host: StandInHost
    let sources: StandInSources
    let provider: BrowserHostProvider

    /// - Parameters:
    ///   - driver: The WebKit driver its calls go to (nil: none).
    ///   - capture: The tab nodes captures vote on (nil: none); the caller keeps it.
    init(driver: (any DriverCallHandler)? = nil, capture: (any ProviderCaptureVoting)? = nil) throws {
        let path = "/tmp/cmux-bh-test-\(getpid())-\(UInt32.random(in: 0...UInt32.max)).sock"
        let clock = TestUptime()
        let input = FakeInput()
        let turns = HeldTurns()
        let links = LinkRequests()
        let work = MainWorkScheduler.testing(budget: MainFrameBudget(input: input, uptimeNanos: clock.read), clock: ManualClock(),
                                             performTurn: turns.perform) { _ in links.make() }
        let sources = StandInSources(socketPath: path)
        self.clock = clock
        self.input = input
        self.turns = turns
        self.links = links
        self.work = work
        self.sources = sources
        host = try StandInHost(listeningAt: path)
        // The provider's own dial (ProviderConnection.dial): the listener's peer is this process.
        provider = BrowserHostProvider(identity: ProviderIdentity(providerID: "test", installID: "test-install"),
                                       credentials: sources, tabs: sources, access: sources, driver: driver,
                                       relay: sources, marking: sources, mainWork: work, capture: capture)
    }

    /// Starts the provider and completes the hello exchange.
    func connect() async throws {
        provider.start()
        try await host.accept()
        let hello = try await host.next { if case .hello = $0 { true } else { false } }
        #expect(hello.tag == "hello")
        await host.send(.helloAck(agentBundle: "", agentBundleSHA: "sha"))
    }

    /// The app refused call `id` (it names no tab).
    func expectRefusal(_ id: UInt64) async throws {
        let reply = try await host.next { if case .result(id, _, _) = $0 { true } else { false } }
        guard case .result(_, let result, let error) = reply else { return }
        #expect(result == nil)
        #expect(error != nil)
    }

    func close() async {
        provider.stop()
        withExtendedLifetime(sources) {}
        await host.close()
    }
}

/// The scheduler's run loop turns, run only when the test says.
@MainActor
final class HeldTurns {
    private var queued: [@MainActor () -> Void] = []
    private var waiter: CheckedContinuation<Void, Never>?

    var perform: MainWorkScheduler.TurnPerformer {
        { [weak self] turn in
            guard let self else { return }
            self.queued.append(turn)
            self.waiter?.resume()
            self.waiter = nil
        }
    }

    /// Waits until a turn is queued (the provider posted a frame's task), then runs every queued turn.
    func runNext() async {
        if queued.isEmpty { await withCheckedContinuation { waiter = $0 } }
        _ = runQueued()
    }

    /// Runs the turns queued now; returns how many ran.
    func runQueued() -> Int {
        let turns = queued
        queued.removeAll()
        for turn in turns { turn() }
        return turns.count
    }
}

/// The scheduler's frame link requests: each makes a fake link; a test awaits the next one.
@MainActor
final class LinkRequests {
    private var unseen = 0
    private var waiter: CheckedContinuation<Void, Never>?

    func make() -> any FrameLink {
        unseen += 1
        waiter?.resume()
        waiter = nil
        return FakeLink()
    }

    /// Waits until the scheduler asked for a link it had not, since the last call.
    func next() async {
        if unseen == 0 { await withCheckedContinuation { waiter = $0 } }
        unseen = 0
    }
}

/// A frame-class client that keeps the scheduler's fake link up, so posts wait for hand-fired frames.
@MainActor
private final class LinkKeeper {
    private let client: FrameClient

    init(on work: MainWorkScheduler) {
        client = FrameClient(owner: "test.keeper", isAnimation: false, on: work.frames) { _ in true }
        client.activate()
    }

    func stop() { client.deactivate() }
}

/// A clock the test moves (`CLOCK_UPTIME_RAW` nanoseconds).
@MainActor
final class TestUptime {
    private var now: UInt64 = 1_000_000_000
    var read: () -> UInt64 { { [self] in self.now } }
    func advance(ms: Double) { now += UInt64(ms * 1_000_000) }
}

@MainActor
final class FakeInput: InputPendingSource {
    var pending = false
    func hasPendingInput(uptime: TimeInterval) -> Bool { pending }
}

@MainActor
final class FakeLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}

/// The browser host's end: a listening socket the provider dials, then the accepted link. Reads and
/// accepts block on the actor's executor (off the main actor, where the provider runs); each is
/// bounded by the socket's receive timeout, so a missing reply fails the test instead of hanging it.
actor StandInHost {
    private let path: String
    private let listener: Int32
    private var fd: Int32 = -1
    private var decoder = ProviderFrameDecoder()

    init(listeningAt path: String) throws {
        let socketFD = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw StandInHostError.socket(errno: errno) }
        self.path = path
        listener = socketFD
        // accept() honors the receive timeout: a provider that never dials fails the test, never hangs it.
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        _ = setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            Darwin.close(socketFD)
            throw StandInHostError.socket(errno: ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, Darwin.listen(socketFD, 1) == 0 else {
            let code = errno
            Darwin.close(socketFD)
            throw StandInHostError.socket(errno: code)
        }
    }

    /// Takes the provider's connection.
    func accept() throws {
        let accepted = Darwin.accept(listener, nil, nil)
        guard accepted >= 0 else { throw StandInHostError.socket(errno: errno) }
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        _ = setsockopt(accepted, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var on: Int32 = 1
        _ = setsockopt(accepted, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        fd = accepted
    }

    /// The next frame from the app that `matches`, skipping the others (tab announcements).
    func next(_ matches: @Sendable (ProviderFrame) -> Bool) throws -> ProviderFrame {
        var buffer = [UInt8](repeating: 0, count: 64 << 10)
        while true {
            while let frame = try decoder.next() {
                if matches(frame) { return frame }
            }
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            guard count > 0 else { throw StandInHostError.readEnded(errno: count < 0 ? errno : 0) }
            buffer.withUnsafeBytes { decoder.push(UnsafeRawBufferPointer(rebasing: $0.prefix(count))) }
        }
    }

    func send(_ frame: ProviderFrame) {
        guard let bytes = try? ProviderCodec.encode(frame) else { return }
        bytes.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count, let base = raw.baseAddress {
                let written = Darwin.write(fd, base + offset, raw.count - offset)
                guard written > 0 else { return }
                offset += written
            }
        }
    }

    /// Ends the accepted connection only (the host keeps listening).
    func dropLink() {
        guard fd >= 0 else { return }
        _ = Darwin.shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
        fd = -1
    }

    func close() {
        if fd >= 0 { Darwin.close(fd) }
        Darwin.close(listener)
        unlink(path)
    }
}

enum StandInHostError: Error {
    /// Creating, binding, listening on or accepting from the socket failed.
    case socket(errno: Int32)
    /// The app closed the link, or no frame came within the receive timeout (`EAGAIN`).
    case readEnded(errno: Int32)
}

/// Every source the provider reads: an observable tab list (empty at first) whose reads it counts, a
/// DevTools relay that starts no tab unless a test sets ``relayReady``, and credentials naming the
/// stand-in host's socket and this process (the listener, so the dialed socket's peer).
@MainActor
final class StandInSources: ProviderCredentialsSource, ProviderTabSource, ProviderAccessSource, ProviderDevToolsRelay,
    ProviderAgentMarking {
    private let socketPath: String
    let list: StandInTabList
    /// Reads of ``providerTabs``.
    private(set) var reads = 0

    init(socketPath: String) {
        self.socketPath = socketPath
        list = StandInTabList()
    }

    func providerCredentials() async -> ProviderCredentials? {
        ProviderCredentials(socketPath: socketPath, secret: ProviderSecret("test-secret"), hostPID: getpid())
    }

    var providerTabs: [ProviderTab] {
        reads += 1
        return list.tabs
    }

    func access(forTab targetID: String) -> ProviderTabAccess {
        ProviderTabAccess(extensionHostAccess: false, userOverride: false, extensions: [])
    }

    /// Whether a tab's relay prepares and starts (false: no tab has a Chromium browser).
    var relayReady = false
    /// What a send to a started relay returns.
    var sendResult = CEFDevToolsRawSend.sent
    /// The raw messages handed to the browser, in order.
    private(set) var relayed: [String] = []
    /// The started relay's callbacks: a raw message from the browser, and the browser going away.
    private(set) var fromBrowser: ((String) -> Void)?
    private(set) var closedByBrowser: (() -> Void)?
    private var startWaiter: CheckedContinuation<Void, Never>?

    func prepareRelay(targetID: String) async -> Bool { relayReady }

    func startRelay(targetID: String, onMessage: @escaping (String) -> Void, onEnd: @escaping () -> Void) -> Bool {
        guard relayReady else { return false }
        fromBrowser = onMessage
        closedByBrowser = onEnd
        startWaiter?.resume()
        startWaiter = nil
        return true
    }

    func send(targetID: String, message: String) -> CEFDevToolsRawSend {
        guard relayReady, fromBrowser != nil else { return .noBrowser }
        if sendResult == .sent { relayed.append(message) }
        return sendResult
    }

    func stopRelay(targetID: String) {
        fromBrowser = nil
        closedByBrowser = nil
    }

    /// How the Chromium Host relays a prepared tab by itself (`cdp.prepare`); nil: the app relays it.
    var direct: CEFAgentDirectTarget?

    func directTarget(targetID: String) -> CEFAgentDirectTarget? { direct }

    /// Each ``keepRendering(targetID:)`` call, as it happens.
    var onKeepRendering: ((String) -> Void)?

    func keepRendering(targetID: String) { onKeepRendering?(targetID) }

    /// Waits until the provider started a relay.
    func started() async {
        if fromBrowser == nil { await withCheckedContinuation { startWaiter = $0 } }
    }

    func agentWillDrive(targetID: String) {}
}

/// The stand-in app's tabs, observable as the store is.
@MainActor @Observable
final class StandInTabList {
    var tabs: [ProviderTab] = []
}
