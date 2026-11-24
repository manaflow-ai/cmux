// DEBUG and Demo builds only: the list rig's live-transport flood (verify/listperf/).
#if DEBUG
import CmuxMobileDesign
import CmuxMobileFeed
import CmuxMobileModel
import CmuxMobileTransport
import Foundation
import OSLog

/// A busy Mac through the real live path, for the list rig (`CMUX_MOBILE_LIST_FLOOD=N`).
///
/// Only the Mac is faked: an in-process daemon (`LiveFloodDaemon`) answers the real `DaemonClient`
/// and streams the events a Mac with many working agents sends. Everything on the phone is the
/// production code: `WorkspaceSync` (event parse, the projection, its publications), `AppStore`
/// (`replaceWorkspaces`, `updateWorkspaces`), `TerminalFeed` (`notificationPosted`, the ledger
/// read, its upserts) and `FeedStore`. The wiring is `LiveCoordinator`'s (`onTree`, `onRows`,
/// `onNotification`, `onItemsChange`), less the parts that need a signed-in account.
///
/// The load (Aziz's Mac, 2026-11-18): `workspaces` working agents whose terminal titles each
/// change `titleHz` times a second (Codex's spinner), one agent report a tick, a new workspace
/// every `addEvery` seconds, and a notification (a Feed item) every `notifyEvery` seconds.
@MainActor
public final class LiveFloodRig {
    public struct Load: Sendable, Equatable {
        /// Working agents (one workspace each): their titles churn and they report.
        public var workspaces: Int
        /// Workspaces the Mac lists at the start (at least `workspaces`; the rest idle).
        public var rows: Int
        public var titleHz: Double
        public var addEvery: Double
        public var notifyEvery: Double
        /// Every `burstEvery` seconds, this many title changes at once (0: none).
        public var burst: Int
        public var burstEvery: Double

        public init(workspaces: Int, rows: Int? = nil, titleHz: Double = 3, addEvery: Double = 2, notifyEvery: Double = 0.5,
                    burst: Int = 0, burstEvery: Double = 5) {
            self.workspaces = max(1, workspaces)
            self.rows = max(self.workspaces, rows ?? workspaces)
            self.titleHz = titleHz
            self.addEvery = addEvery
            self.notifyEvery = notifyEvery
            self.burst = burst
            self.burstEvery = burstEvery
        }
    }

    public let sync: WorkspaceSync
    public let terminalFeed: TerminalFeed
    private let daemon: LiveFloodDaemon
    private let store: AppStore
    private let macID: String
    /// Store publications the rig saw (logged at the end: what the flood cost the main thread).
    public private(set) var treePublications = 0
    public private(set) var rowPublications = 0
    private let log = Logger(subsystem: "dev.cmux.mobile", category: "frames")
    /// The list measured (`ListApplyProbe` name: `workspaces` or `feed`).
    private let list: String
    /// The oldest store write the list has not applied yet (uptime seconds).
    private var unappliedSince: TimeInterval?
    private var applies = 0
    private var writes = 0
    private var latencies: [Double] = []
    private var allLatencies: [Double] = []
    private var secondApplies: [Int] = []
    private var ticker: Task<Void, Never>?

    public init(store: AppStore, feedStore: FeedStore, macID: String, load: Load, list: String) {
        self.store = store
        self.macID = macID
        self.list = list
        daemon = LiveFloodDaemon(load: load)
        sync = WorkspaceSync(deviceID: "list-rig", deviceName: "iPhone")
        terminalFeed = TerminalFeed(store: feedStore)
        let sync = sync
        let terminalFeed = terminalFeed
        // As `LiveCoordinator.wire(_:)` does.
        terminalFeed.request = { [weak sync] command, params, connection in
            guard let sync, sync.connectionSerial == connection, let client = sync.daemon else {
                throw LinkError(code: "no-link", message: "Not connected to the Mac")
            }
            var fields: [String: Any] = [:]
            for (key, value) in params { fields[key] = value }
            return try await client.request(command, params: fields)
        }
        sync.onTree = { [weak self] tree in
            guard let self else { return }
            treePublications += 1
            let revision = self.store.workspacesRevision
            self.store.replaceWorkspaces(macID: self.macID, with: tree.workspaces)
            if self.list == "workspaces", self.store.workspacesRevision != revision { self.noteWrite() }
            terminalFeed.treeChanged(tree, macID: self.macID, connection: self.sync.connectionSerial)
        }
        sync.onRows = { [weak self] tree, ids, agentChanged in
            guard let self else { return }
            rowPublications += 1
            let revision = self.store.workspacesRevision
            self.store.updateWorkspaces(macID: self.macID, rows: tree.workspaces.filter { ids.contains($0.id) })
            if self.list == "workspaces", self.store.workspacesRevision != revision { self.noteWrite() }
            if agentChanged {
                terminalFeed.treeChanged(tree, macID: self.macID, connection: self.sync.connectionSerial, changedWorkspaceIDs: ids)
            } else {
                terminalFeed.updateTreeMetadata(tree)
            }
        }
        sync.onNotification = { post in terminalFeed.notificationPosted(post) }
        feedStore.onItemsChange = { [weak self] items in
            if self?.list == "feed" { self?.noteWrite() }
            terminalFeed.itemsChanged(items)
        }
        ListApplyProbe.shared.onApply = { [weak self] applied in
            guard let self, applied == self.list else { return }
            applies += 1
            if let since = unappliedSince {
                let ms = (ProcessInfo.processInfo.systemUptime - since) * 1000
                latencies.append(ms)
                allLatencies.append(ms)
                unappliedSince = nil
            }
        }
    }

    private func noteWrite() {
        writes += 1
        if unappliedSince == nil { unappliedSince = ProcessInfo.processInfo.systemUptime }
    }

    /// One line a second: the list's applies, the store writes it had to show, and how long a
    /// write waited for its apply (p95, max).
    private func logSecond() {
        log.notice("FRAMELOG list-stress flood-second list=\(self.list, privacy: .public) applies=\(self.applies, privacy: .public) writes=\(self.writes, privacy: .public) write_to_apply_p95_ms=\(Self.p95(self.latencies), privacy: .public) write_to_apply_max_ms=\(self.latencies.max() ?? 0, privacy: .public)")
        secondApplies.append(applies)
        applies = 0
        writes = 0
        latencies = []
    }

    nonisolated static func p95(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return (sorted[min(sorted.count - 1, Int((Double(sorted.count) * 0.95).rounded(.up)) - 1)] * 10).rounded() / 10
    }

    /// Binds the fake Mac and waits for its first list, then starts the flood.
    public func start() async {
        await sync.bind(daemon, macID: macID)
        log.notice("FRAMELOG list-stress flood bound workspaces=\(self.store.workspaces.count, privacy: .public)")
        await daemon.startFlood()
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.logSecond()
            }
        }
    }

    /// What the flood cost the store: its publications, logged once at the end of the run.
    public func logSummary() {
        ticker?.cancel()
        let perSecond = secondApplies.isEmpty ? 0 : Double(secondApplies.reduce(0, +)) / Double(secondApplies.count)
        log.notice("FRAMELOG list-stress flood-summary list=\(self.list, privacy: .public) applies_per_s=\((perSecond * 10).rounded() / 10, privacy: .public) applies_per_s_max=\(self.secondApplies.max() ?? 0, privacy: .public) write_to_apply_p95_ms=\(Self.p95(self.allLatencies), privacy: .public) write_to_apply_max_ms=\(self.allLatencies.max() ?? 0, privacy: .public) samples=\(self.allLatencies.count, privacy: .public)")
        log.notice("FRAMELOG list-stress flood tree_publications=\(self.treePublications, privacy: .public) row_publications=\(self.rowPublications, privacy: .public) workspaces=\(self.store.workspaces.count, privacy: .public) feed=\(self.terminalFeed.store.items.count, privacy: .public)")
    }
}

/// The Mac's daemon, faked: answers setup, `list-workspaces` (`unchanged` once it has a
/// `known`), `list-agents` and `list-notifications`, and streams title, agent, add and
/// notification events at the rig's load. JSON is built on this actor, off the main thread,
/// as on the Mac.
actor LiveFloodDaemon: LinkChannel {
    nonisolated let id: UInt32 = 1
    private let load: LiveFloodRig.Load
    private var inbox: [Data] = []
    private var receiver: CheckedContinuation<Data?, Never>?
    private var closed = false
    private var flood: Task<Void, Never>?
    private var count: Int
    private var revision = 1
    private var titles: [Int: Int] = [:]
    private var ledger: [[String: Any]] = []
    private var notified = 0
    private static let spinner = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
    private static let tasks = ["Refactor the dialer", "Fix the relay drop", "Add transport tests", "Port the Feed to UIKit",
                                "Profile the terminal", "Review PR #46856", "Write the migration", "Trim the sidebar"]

    init(load: LiveFloodRig.Load) {
        self.load = load
        count = load.rows
    }

    func startFlood() {
        guard flood == nil else { return }
        flood = Task { [weak self] in await self?.run() }
    }

    /// 20 ticks a second (rig pacing, not synchronization).
    private func run() async {
        let tickHz = 20.0
        let titlesPerTick = max(1, Int((Double(load.workspaces) * load.titleHz / tickHz).rounded()))
        let addTicks = max(1, Int(load.addEvery * tickHz))
        let notifyTicks = max(1, Int(load.notifyEvery * tickHz))
        let burstTicks = max(1, Int(load.burstEvery * tickHz))
        var tick = 0
        var cursor = 0
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled, !closed else { return }
            tick += 1
            // The working agents' spinners (the idle rows stay still).
            let changes = titlesPerTick + (load.burst > 0 && tick % burstTicks == 0 ? load.burst : 0)
            for _ in 0..<changes {
                cursor = cursor % load.workspaces + 1
                titles[cursor, default: 0] += 1
                push(["event": "title-changed", "surface": cursor, "title": title(cursor)])
            }
            // An agent report: a turn going on (its time moves), now and then one stopping to ask.
            let agent = (tick * 7) % load.workspaces + 1
            push(["event": "agent-changed", "surface": agent, "state": tick % 40 == 0 ? "blocked" : "working", "agent": "codex",
                  "updated_at_ms": Int(Date().timeIntervalSince1970 * 1000)])
            if tick % addTicks == 0 { addWorkspace() }
            if tick % notifyTicks == 0 { notify((tick / notifyTicks * 13) % load.workspaces + 1) }
        }
    }

    private func title(_ surface: Int) -> String {
        let spin = Self.spinner[(titles[surface] ?? 0) % Self.spinner.count]
        return "\(spin) codex: \(Self.tasks[surface % Self.tasks.count])"
    }

    private func row(_ surface: Int) -> [String: Any] {
        ["id": surface, "key": "rig-ws-\(surface)", "name": "Agent \(surface): \(Self.tasks[surface % Self.tasks.count])",
         "screens": [["id": surface, "active": true, "active_pane": surface,
                      "panes": [["id": surface, "active_tab": 0,
                                 "tabs": [["surface": surface, "kind": "pty", "title": title(surface),
                                           "cwd": "/Users/aziz/Development/cmux"]]]]]]]
    }

    private func addWorkspace() {
        count += 1
        revision += 1
        push(["event": "workspace-added", "workspace": count, "index": 0, "workspace_revision": revision, "entity": row(count)])
        push(["event": "agent-changed", "surface": count, "state": "working", "agent": "codex",
              "updated_at_ms": Int(Date().timeIntervalSince1970 * 1000)])
    }

    private func notify(_ surface: Int) {
        notified += 1
        let id = "rig-n\(notified)"
        let now = Int(Date().timeIntervalSince1970 * 1000)
        ledger.append(["id": id, "title": "Codex finished", "body": "Agent \(surface) finished a turn (\(notified))", "level": "info",
                       "surface": surface, "created_at_ms": now, "source": "agent", "acknowledged": false])
        if ledger.count > 256 { ledger.removeFirst(ledger.count - 256) }
        push(["event": "notification", "id": id, "surface": surface, "source": "agent",
              "prompt": "Make the dialer retry with backoff (\(notified))",
              "message": "**Done.** The dialer now retries with exponential backoff, capped at 30 s. 24 tests pass."])
    }

    // MARK: LinkChannel

    func send(_ data: Data) {
        for line in data.split(separator: 0x0A) {
            guard let request = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let id = request["id"] as? String else { continue }
            var reply: [String: Any] = ["id": id, "ok": true, "data": [String: Any]()]
            switch request["cmd"] as? String ?? request["operation"] as? String {
            case "identify":
                reply["data"] = ["app": "cmux-tui", "version": "rig", "protocol": 1, "capabilities": [WorkspaceSync.knownCapability]]
            case "list-workspaces":
                if let known = request["known"] as? [String: Any], !known.isEmpty {
                    // Every change went out as an event: the phone's tree is current.
                    reply["data"] = ["unchanged": true]
                } else {
                    // A tree revision, as the real daemon sends: the phone's next list carries
                    // it back as `known` and gets the short `unchanged` answer.
                    reply["data"] = ["tree_revision": "rig-\(revision)", "workspace_revision": revision,
                                     "workspaces": (1...count).map(row)]
                }
            case "list-agents":
                let now = Int(Date().timeIntervalSince1970 * 1000)
                reply["data"] = ["agents": (1...load.workspaces).map { ["surface": $0, "state": "working", "agent": "codex", "updated_at_ms": now] }]
            case "list-notifications":
                let limit = request["limit"] as? Int ?? 100
                reply["data"] = ["notifications": Array(ledger.suffix(limit))]
            case "sidebar_layout.get":
                reply = ["id": id, "ok": false, "error": ["code": "unsupported", "message": "rig"]]
            default:
                break
            }
            push(reply)
        }
    }

    func receive() async -> Data? {
        if !inbox.isEmpty { return inbox.removeFirst() }
        if closed { return nil }
        return await withCheckedContinuation { receiver = $0 }
    }

    func close(code: String, reason: String) {
        closed = true
        flood?.cancel()
        inbox = []
        receiver?.resume(returning: nil)
        receiver = nil
    }

    private func push(_ object: [String: Any]) {
        guard !closed, var bytes = try? JSONSerialization.data(withJSONObject: object) else { return }
        bytes.append(0x0A)
        if let receiver {
            self.receiver = nil
            receiver.resume(returning: bytes)
        } else {
            inbox.append(bytes)
        }
    }
}
#endif
