import CmuxMobileModel
import Foundation

// The Workspaces list's on-device cache, SMALL and GOD (instant-perf.md, `workspaces_cold_paint_from_cache`):
// one Mac's workspaces as the phone last saw them, saved by `LiveSnapshotStore` the way the app
// saves them. Small: 20 workspaces. God: 5,000, in the Mac's sidebar order, with 24 pinned,
// 40 groups, 2 to 9 tabs each (agent tabs waiting or working, browser tabs with URLs, terminals),
// one to three screens and six months of activity times. Seeded, built in memory, never checked in.

enum WorkspaceCacheFixture {
    static let accountID = "bench-user"
    static let mac = MacDevice(id: "mac-bench", name: "Studio", isOnline: true, machineID: "machine-bench")

    static func count(_ size: InstantPerfSize) -> Int { size == .small ? 20 : 5_000 }

    /// The rows, built once per size.
    static func workspaces(_ size: InstantPerfSize) -> [Workspace] { size == .small ? small : god }
    private static let small = make(count(.small), seed: 11)
    private static let god = make(count(.god), seed: 12)

    static func snapshot(_ size: InstantPerfSize) -> LiveSnapshot {
        LiveSnapshot(teamID: "team-bench", teamName: "Bench", macs: [mac], linkedMacID: mac.id,
                     workspaces: [mac.id: .init(workspaces: workspaces(size), savedAt: Date(timeIntervalSince1970: 1_800_000_000))])
    }

    /// A store holding `size`'s cache on disk, written as the app writes it (setup, untimed).
    static func store(_ size: InstantPerfSize) -> (store: LiveSnapshotStore, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "instant-perf-workspaces-\(size.rawValue)-\(UUID().uuidString)", directoryHint: .isDirectory)
        let store = LiveSnapshotStore(directory: directory)
        store.save(snapshot(size), accountID: accountID)
        store.flush()
        return (store, directory)
    }

    private static func make(_ count: Int, seed: UInt64) -> [Workspace] {
        var rng = SeededRandom(seed: seed)
        let groups = (0..<40).map { MacWorkspaceGroup(id: "g\($0)", name: "Group \($0)", color: "blue", index: $0) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let harnesses = ["claude", "codex", "opencode"]
        return (0..<count).map { index in
            var tabs: [WorkspaceTab] = []
            for t in 0..<rng.int(2...9) {
                let id = "tab-\(index)-\(t)"
                switch rng.int(0...3) {
                case 0:
                    let status: WorkspaceTab.AgentStatus? = rng.chance(10) ? .waiting : rng.chance(20) ? .working : nil
                    tabs.append(WorkspaceTab(id: id, kind: .agent, title: "Fix the relay retry \(index)",
                                             subtitle: "~/src/cmux", harness: harnesses[rng.int(0...2)], agentStatus: status))
                case 1:
                    tabs.append(WorkspaceTab(id: id, kind: .browser, title: "PR #\(rng.int(1...49_999))",
                                             url: URL(string: "https://github.com/acme/app/pull/\(rng.int(1...49_999))")))
                default:
                    tabs.append(WorkspaceTab(id: id, kind: .terminal, title: "zsh", subtitle: "~/src/app-\(index % 97)"))
                }
            }
            var ws = Workspace(
                id: "ws-\(index)", macID: mac.id, title: "workspace \(index) \(index % 7 == 0 ? "release train" : "fix")",
                directory: "/Users/me/src/app-\(index % 97)", branch: rng.chance(70) ? "lane/fix-\(index)" : nil, tabs: tabs,
                lastActivityAt: now.addingTimeInterval(-Double(rng.int(0...15_552_000))),
                colorHex: rng.chance(30) ? "blue" : nil, icon: rng.chance(10) ? "hammer" : nil,
                hasActivityTime: rng.chance(90), focusOrder: count - index, activeTabID: tabs.first?.id)
            ws.isPinned = index < min(24, count / 4)
            ws.pinIndex = ws.isPinned ? index : nil
            ws.sidebarIndex = index
            ws.resourceID = "ws_\(index)"
            if !ws.isPinned, rng.chance(40) { ws.group = groups[(index / 25) % groups.count] }
            let screenCount = rng.int(1...3)
            ws.screens = (0..<screenCount).map { s in
                MacScreen(id: s + 1, isActive: s == 0, activePane: s * 10 + 1, panes: [s * 10 + 1, s * 10 + 2],
                          tabIDs: tabs.enumerated().filter { $0.offset % screenCount == s }.map(\.element.id))
            }
            return ws
        }
    }
}
