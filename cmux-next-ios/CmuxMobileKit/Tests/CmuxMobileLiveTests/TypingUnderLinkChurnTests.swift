#if os(iOS)
import CmuxMobileAgentChat
import CmuxMobileFeed
import CmuxMobileModel
import CmuxMobileTransport
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import CmuxMobileLive
@testable import CmuxMobileWorkspaces

/// Leo, 2026-11-24: "im also still noticing in intervals lag spikes when just typing on phone. we cant be
/// exposing that kind of stuff. im just lte connecting to my mac and all".
///
/// Typing on a phone linked to its Mac over LTE, with the link's periodic work running as it does on a
/// phone: the heartbeat probe (every 2.5 s while the link is quiet) and the Rust link's pong reports
/// (every 3 s with a terminal on screen), each with a new round trip (80 ms with jitter). A pong must
/// not reach anything a keystroke waits on: before the fix every one of them re-ran the coordinator's
/// whole link update on the main thread (the store's connection state written, the workspace list and
/// the open workspace's tabs re-run, the saved list rebuilt and compared).
///
/// Keystrokes go out at a steady 12.5 a second for 22 s over an emulated LTE path (40 ms each way,
/// 10% jitter, 1% loss with a 200 ms retransmit, delivered in order) and their echoes come back to the
/// main actor, where the glyph is drawn into a label in a window. It prints one line,
/// `TYPINGLAG keys=… p50_ms=… p99_ms=… max_ms=… worst_stall_ms=… pongs=… connection_writes=…`:
/// keystroke to glyph, and the main thread's longest stall (a watchdog thread asks main for a turn every
/// 4 ms and times the answer).
@MainActor @Suite(.serialized, .timeLimit(.minutes(2)))
struct TypingUnderLinkChurnTests {
    static let typingSeconds = 22.0
    static let keyInterval = 0.08
    static let oneWayMs = 40.0
    static let lossRate = 0.01
    static let retransmitMs = 200.0
    static let workspaces = 40
    static let tabsPerWorkspace = 6

    @Test func typingOverLTEDoesNotWaitOnLinkPongs() async throws {
        let key = "cmuxMobile.live.mac.t-typinglag"
        UserDefaults.standard.removeObject(forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let store = AppStore(teams: [], activeTeamID: "", workspaces: [], feed: [], tabMemory: .inMemory())
        let dialer = ChurnDialer(workspaces: Self.workspaces, tabs: Self.tabsPerWorkspace)
        let live = Self.coordinator(store: store, dialer: dialer)
        defer { live.stop() }
        await settle { store.macConnection["m1"] == .connected && store.workspaces.filter { $0.macID == "m1" }.count >= Self.workspaces }
        let opened = try #require(store.workspaces.first { $0.macID == "m1" })

        // What the phone has on screen while the person types: the workspace list under the open
        // workspace, whose tabs source reads the Mac's connection state.
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        let creator = WorkspaceCreator(store: store, backend: MockWorkspaceCreationBackend(latency: .zero))
        let list = UIHostingController(rootView: WorkspacesList(store: store, creator: creator, open: { _ in }))
        window.rootViewController = list
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let tabs = WorkspaceTabsSource(store: store, workspaceID: opened.id)
        tabs.refreshTabs()
        let glyphs = Glyphs()
        list.view.addSubview(glyphs.label)
        await drain()

        // Every write of the Mac's connection state from here on, and every pong that reached the store.
        let writes = StoreWatch(store) { _ = $0.macConnection }
        let pongs = StoreWatch(store) { _ = $0.macLinkDiagnostics["m1"] }

        dialer.startChurn()
        let watchdog = MainStallWatchdog()
        watchdog.start()
        let path = LTEPath(oneWayMs: Self.oneWayMs, lossRate: Self.lossRate, retransmitMs: Self.retransmitMs)
        let start = CACurrentMediaTime()
        var sent = 0
        while CACurrentMediaTime() - start < Self.typingSeconds {
            let at = CACurrentMediaTime()
            let character = Character(UnicodeScalar(UInt8(97 + sent % 26)))
            sent += 1
            path.send { @MainActor in glyphs.draw(character, sentAt: at) }
            try? await Task.sleep(for: .milliseconds(Int(Self.keyInterval * 1000))) // test: steady typing rate
        }
        // The last echoes are in flight: wait for them (bounded by the suite's time limit).
        while glyphs.latencies.count < sent, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) } // test: waits for echoes
        dialer.stopChurn()
        let worstStall = watchdog.stop()

        let sorted = glyphs.latencies.sorted()
        func percentile(_ q: Double) -> Double { sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * q).rounded()))] }
        let line = "TYPINGLAG keys=\(sorted.count) p50_ms=\(Self.f(percentile(0.5))) p99_ms=\(Self.f(percentile(0.99))) "
            + "max_ms=\(Self.f(sorted.last ?? 0)) worst_stall_ms=\(Self.f(worstStall)) pongs=\(pongs.value) "
            + "connection_writes=\(writes.value) duress=lte_rtt80ms_jitter10pct_loss1pct_pong3s_probe2.5s"
        print(line)
        Attachment.record(line, named: "typing-lag-lte.txt")

        #expect(sorted.count == sent)
        // The pongs really came, each with a new round trip (the diagnostics line shows it)...
        #expect(pongs.value >= 4)
        // ...and none of them wrote the Mac's connection state: the link stayed up the whole time.
        #expect(writes.value == 0)
    }

    // MARK: Harness

    static func f(_ value: Double) -> String { String(format: "%.1f", value) }

    static func coordinator(store: AppStore, dialer: ChurnDialer) -> LiveCoordinator {
        let host = "svc-\(UUID().uuidString.prefix(8).lowercased()).cmuxMobile.test"
        let userID = "user-\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory.appending(path: "cmux-mobile-typinglag-\(UUID().uuidString)")
        let snapshots = LiveSnapshotStore(directory: directory)
        snapshots.save(LiveSnapshot(
            teamID: "t-typinglag", teamName: "One",
            macs: [MacDevice(id: "m1", name: "Leo's MacBook Pro", isOnline: true)],
            linkedMacID: "m1",
            workspaces: ["m1": .init(workspaces: [], savedAt: Date(timeIntervalSince1970: 1_000))]
        ), accountID: userID)
        snapshots.flush()
        return LiveCoordinator(
            store: store,
            api: LiveAPI(baseURL: URL(string: "https://\(host)")!, session: ServiceStub.session()) { _ in "token" },
            identity: DeviceIdentity(link: UUID().uuidString, presence: UUID().uuidString),
            userID: userID, deviceName: "iPhone", transport: .wireGuard, dialer: dialer,
            feedStore: FeedStore(items: []), snapshots: snapshots
        )
    }

    func settle(_ done: () -> Bool) async {
        while !done(), !Task.isCancelled { try? await Task.sleep(for: .milliseconds(1)) } // test: polls the condition
    }

    func drain() async {
        for _ in 0..<50 { try? await Task.sleep(for: .milliseconds(2)) }
    }
}

/// The terminal's glyphs: each echo drawn into a label in the window, timed from its keystroke.
@MainActor private final class Glyphs {
    let label = UILabel(frame: CGRect(x: 0, y: 700, width: 393, height: 100))
    private(set) var latencies: [Double] = []
    private var text = ""

    init() { label.numberOfLines = 0 }

    func draw(_ character: Character, sentAt: CFTimeInterval) {
        text.append(character)
        if text.count > 200 { text.removeFirst(100) }
        label.text = text
        label.layoutIfNeeded()
        latencies.append((CACurrentMediaTime() - sentAt) * 1000)
    }
}

/// Counts the changes to what `read` reads in the store (observed again after each).
@MainActor private final class StoreWatch {
    private(set) var value = 0
    private let store: AppStore
    private let read: @MainActor (AppStore) -> Void

    init(_ store: AppStore, _ read: @escaping @MainActor (AppStore) -> Void) {
        self.store = store
        self.read = read
        watch()
    }

    private func watch() {
        withObservationTracking { read(store) } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                value += 1
                watch()
            }
        }
    }
}

/// The emulated LTE path for keystrokes and their echoes: `oneWayMs` each way with 10% jitter, a lost
/// packet (`lossRate`, each way) retransmitted after `retransmitMs`, delivered in order (a late
/// keystroke holds the ones behind it, as the link's stream does). The echo lands on the main actor.
private final class LTEPath: @unchecked Sendable {
    let oneWayMs: Double
    let lossRate: Double
    let retransmitMs: Double
    private let queue = DispatchQueue(label: "typing-lag.lte")
    private var lastDelivery: CFTimeInterval = 0
    private var rng = SystemRandomNumberGenerator()

    init(oneWayMs: Double, lossRate: Double, retransmitMs: Double) {
        self.oneWayMs = oneWayMs
        self.lossRate = lossRate
        self.retransmitMs = retransmitMs
    }

    private func leg() -> Double {
        var ms = oneWayMs * Double.random(in: 0.9...1.1, using: &rng)
        if Double.random(in: 0..<1, using: &rng) < lossRate { ms += retransmitMs }
        return ms
    }

    func send(_ echo: @escaping @MainActor @Sendable () -> Void) {
        let now = CACurrentMediaTime()
        queue.sync {
            let due = max(now + (leg() + leg()) / 1000, lastDelivery)
            lastDelivery = due
            queue.asyncAfter(deadline: .now() + max(0, due - now)) {
                Task { @MainActor in echo() }
            }
        }
    }
}

/// The main thread's longest stall: a thread asks main for a turn every 4 ms and times each answer.
private final class MainStallWatchdog: @unchecked Sendable {
    private let lock = NSLock()
    private var running = false
    private var worst: Double = 0
    private var thread: Thread?

    func start() {
        lock.withLock { running = true }
        let thread = Thread { [self] in
            while lock.withLock({ running }) {
                let asked = CACurrentMediaTime()
                let answered = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { answered.signal() }
                answered.wait()
                let ms = (CACurrentMediaTime() - asked) * 1000
                lock.withLock { worst = max(worst, ms) }
                Thread.sleep(forTimeInterval: 0.004)
            }
        }
        self.thread = thread
        thread.start()
    }

    /// Stops the watch and returns the longest stall (ms).
    func stop() -> Double {
        lock.withLock {
            running = false
            return worst
        }
    }
}

/// Dials links whose round trip changes on every pong, as an LTE link's does.
final class ChurnDialer: MacLinkDialer, @unchecked Sendable {
    private let lock = NSLock()
    private var links: [ChurnLink] = []
    private let listing: String

    init(workspaces: Int, tabs: Int) {
        var surface = 0
        var rows: [String] = []
        for index in 1...workspaces {
            var tabRows: [String] = []
            for tab in 0..<tabs {
                surface += 1
                tabRows.append(#"{"surface":\#(surface),"kind":"pty","title":"zsh \#(tab)"}"#)
            }
            rows.append(#"{"id":\#(index),"key":"ws-\#(index)","name":"project-\#(index)","screens":[{"id":1,"active":true,"active_pane":1,"panes":[{"id":1,"active_tab":0,"tabs":[\#(tabRows.joined(separator: ","))]}]}]}"#)
        }
        listing = rows.joined(separator: ",")
    }

    func dial(_ endpoint: LinkEndpoint, transport: CmuxMobileTransport.TransportKind, accessToken: String) async throws -> any MacLink {
        let listing = listing
        let inner = MockMacLink(transport: transport) { service, data in
            guard service == "daemon" else { return [] }
            return data.split(separator: 0x0A).compactMap { request -> Data? in
                guard let object = try? JSONSerialization.jsonObject(with: Data(request)) as? [String: Any],
                      let id = object["id"] as? String else { return nil }
                let line: String = switch object["cmd"] as? String ?? "" {
                case "list-workspaces": #"{"id":"\#(id)","ok":true,"data":{"workspaces":[\#(listing)]}}"#
                case "list-agents": #"{"id":"\#(id)","ok":true,"data":{"agents":[]}}"#
                case "read-screen": #"{"id":"\#(id)","ok":true,"data":{"text":"$ "}}"#
                default: #"{"id":"\#(id)","ok":true,"data":{}}"#
                }
                return Data(line.utf8) + Data([0x0A])
            }
        }
        let link = ChurnLink(inner: inner)
        lock.withLock { links.append(link) }
        return link
    }

    func startChurn() { lock.withLock { links }.forEach { $0.startChurn() } }
    func stopChurn() { lock.withLock { links }.forEach { $0.stopChurn() } }
}

/// A link that answers like `MockMacLink` but reports a new LTE round trip (80 ms, jittered) on every
/// pong: its heartbeat pings and, every 3 s once churning, a `connected` state as the Rust link sends.
final class ChurnLink: MacLink, @unchecked Sendable {
    let inner: MockMacLink
    let states: AsyncStream<LinkState>
    private let continuation: AsyncStream<LinkState>.Continuation
    private var churn: Task<Void, Never>?
    private let lock = NSLock()

    init(inner: MockMacLink) {
        self.inner = inner
        (states, continuation) = AsyncStream.makeStream()
        continuation.yield(.connected(inner.transport, .direct, rttMillis: 80))
    }

    static func rtt() -> UInt32 { UInt32.random(in: 64...104) }

    var transport: CmuxMobileTransport.TransportKind { inner.transport }
    var connectedPath: LinkPathKind? { .direct }

    func openChannel(service: String, args: [String: String]) async throws -> any LinkChannel {
        try await inner.openChannel(service: service, args: args)
    }

    func ping() async throws -> UInt32 { Self.rtt() }

    func startChurn() {
        let continuation = continuation
        let transport = inner.transport
        lock.withLock {
            churn = Task.detached {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(3)) // test: the Rust link's pong cadence
                    guard !Task.isCancelled else { return }
                    continuation.yield(.connected(transport, .direct, rttMillis: ChurnLink.rtt()))
                }
            }
        }
    }

    func stopChurn() { lock.withLock { churn?.cancel() } }

    func close() async {
        stopChurn()
        continuation.yield(.disconnected(reason: "closed"))
        continuation.finish()
    }
}
#endif
