import AppKit
import CmuxNextActions
import CmuxNextAgentActivity
@testable import CmuxNextAgentLanes
import CmuxNextAgentPane
import Foundation
import Testing

/// The Dock icon's menu: which chats Continue, Unread and Recent list and in what order, and that
/// building the menu reads only cached values (no host call in the menu's own turn).
@MainActor @Suite
struct DockMenuTests {
    static func lane(_ id: String, title: String? = nil, updated: TimeInterval, unread: Bool = false,
                     hidden: Bool = false) -> AgentActivityLane {
        AgentActivityLane(id: id, name: "name-\(id)", title: title ?? "Chat \(id)", peer: nil, parent: nil, state: .idle,
                          since: Date(timeIntervalSince1970: updated), error: nil, unread: unread,
                          updatedAt: Date(timeIntervalSince1970: updated), sidebarRequiresOpen: hidden)
    }

    @Test func continueIsTheNewestChatAndRecentFollowsIt() {
        let lanes = (1...6).map { Self.lane("c\($0)", updated: TimeInterval($0)) }
        let chats = DockMenuChats.make(lanes: lanes, marks: .init(), now: Date(timeIntervalSince1970: 100))
        #expect(chats.last?.id == "c6")
        #expect(chats.recent.map(\.id) == ["c5", "c4", "c3"])
        #expect(chats.recentMore.map(\.id) == ["c2", "c1"])
        #expect(chats.unread.isEmpty && chats.unreadMore.isEmpty)
    }

    @Test func unreadLeavesReadArchivedSnoozedAndHiddenChatsOut() {
        let read = Self.lane("read", updated: 9, unread: true)
        let lanes = [Self.lane("u1", updated: 8, unread: true), Self.lane("u2", updated: 7, unread: true),
                     Self.lane("u3", updated: 6, unread: true), Self.lane("u4", updated: 5, unread: true),
                     read, Self.lane("gone", updated: 10, unread: true), Self.lane("nap", updated: 11, unread: true),
                     Self.lane("agent", updated: 12, unread: true, hidden: true), Self.lane("old", updated: 1)]
        var marks = AgentPriorityMarks.State()
        marks.read["read"] = AgentPriorityMarks.stamp(read)
        marks.archived = ["gone"]
        let nap = Self.lane("nap", updated: 11, unread: true)
        marks.snoozed["nap"] = .init(stamp: AgentPriorityMarks.stamp(nap), until: Date(timeIntervalSince1970: 1000))
        let chats = DockMenuChats.make(lanes: lanes, marks: marks, now: Date(timeIntervalSince1970: 100))
        #expect(chats.last?.id == "read")
        #expect(chats.unread.map(\.id) == ["u1", "u2", "u3"])
        #expect(chats.unreadMore.map(\.id) == ["u4"])
        // Recent leaves out Continue's chat and the unread ones already shown.
        #expect(chats.recent.map(\.id) == ["u4", "old"])
    }

    @Test func titlesFitOnOneShortLine() {
        #expect(DockMenuChats.title("  Fix\nthe   dock\tmenu ") == "Fix the dock menu")
        let long = DockMenuChats.title(String(repeating: "a", count: 80), limit: 10)
        #expect(long == "aaaaaaaaa…" && long.count == 10)
        let empty = DockMenuChats.make(lanes: [Self.lane("x", title: "", updated: 1)], marks: .init())
        #expect(empty.last?.title == "name-x")
    }

    @Test func choicesListUsableHarnessesAndMachinesOnlyWhenThereIsMoreThanThisMac() {
        let rows = [AcpmuxHarnessRow(id: "codex", kind: "acp", source: "path"),
                    AcpmuxHarnessRow(id: "broken", kind: "acp", source: "path", problem: "not signed in"),
                    AcpmuxHarnessRow(id: "claude", name: "Claude", kind: "claude-stdio", source: "path")]
        let local = AgentChatDestinations.local(title: "This Mac")
        let alone = DockMenuChoices.make(harnesses: rows, machines: [local])
        #expect(alone.harnesses.map(\.title) == ["Claude", "Codex"])
        #expect(alone.machines.isEmpty)
    }

    @MainActor final class Host: DockMenuHost {
        var reads = 0
        var newChats: [[String: ActionValue]] = []
        var opened: [String] = []
        func dockMenuHarnesses() async -> [AcpmuxHarnessRow] { reads += 1; return [AcpmuxHarnessRow(id: "codex", kind: "acp", source: "path")] }
        func dockMenuMachines() async -> [AgentChatDestinations.Destination] { [] }
        var dockMenuHasWindow = true
        var dockMenuHasPane = true
        var dockMenuWindow: DockMenuWindow { !dockMenuHasWindow ? .closed : dockMenuHasPane ? .pane : .noPane }
        var reopens = 0
        /// What the reopen does in its own call (a closed window brought back mounts its panes there).
        var onReopen: (() -> Void)?
        func dockMenuReopenWindow() { reopens += 1; onReopen?() }
        func dockMenuNewChat(_ arguments: [String: ActionValue]) { newChats.append(arguments) }
        /// Chats a tab already shows: they open with no pane, as a session link reveals its tab.
        var shownChats: Set<String> = []
        struct NoPane: Error {}
        func dockMenuOpenChat(_ id: String) throws {
            guard dockMenuWindow == .pane || (dockMenuWindow != .closed && shownChats.contains(id)) else { throw NoPane() }
            opened.append(id)
        }
        func dockMenuRefuse(_ reason: String) {}
    }

    @Test func theMenuIsBuiltFromCachedRowsWithoutCallingTheHost() {
        let host = Host()
        let controller = DockMenuController(lanes: AgentLaneStore(), marks: AgentPriorityMarks(defaults: nil), host: host)
        let menu = controller.menu()
        // The read for the next open is started, not awaited: nothing ran in the menu's turn.
        #expect(host.reads == 0)
        #expect(menu.items.map(\.title) == [DockMenuStrings.newChat])
        controller.stop()
    }

    @Test func rowsRunInOrderWithSectionHeadersAndForwardTheirAction() throws {
        let chats = DockMenuChats(last: .init(id: "a", title: "Alpha"), unread: [.init(id: "b", title: "Beta")],
                                  recent: [.init(id: "c", title: "Gamma")], recentMore: [.init(id: "d", title: "Delta")])
        let choices = DockMenuChoices(harnesses: [.init(id: "codex", title: "Codex")], machines: [.init(id: "local", title: "This Mac"), .init(id: "peer:m", title: "m")])
        let menu = DockMenuBuilder.menu(chats: chats, choices: choices, target: nil, action: NSSelectorFromString("pick:"))
        #expect(menu.items.map(\.title) == [DockMenuStrings.newChat, DockMenuStrings.newChatIn, DockMenuStrings.continueChat("Alpha"),
                                            "", DockMenuStrings.unread, "Beta", "", DockMenuStrings.recent, "Gamma", DockMenuStrings.more])
        #expect(menu.items[4].isEnabled == false && menu.items[7].isEnabled == false)
        let newIn = try #require(menu.items[1].submenu)
        #expect(newIn.items.map(\.title) == ["Codex", "", "This Mac", "m"])
        let box = try #require(newIn.items[3].representedObject as? DockMenuBuilder.Box)
        #expect(box.action == .newChat(harness: nil, machine: "peer:m"))
        let more = try #require(menu.items[9].submenu)
        #expect((more.items[0].representedObject as? DockMenuBuilder.Box)?.action == .open(chat: "d"))
    }

    /// #33238: with no window open, a row opens one and runs once its first pane mounts, keeping
    /// New Chat in ▸'s harness or machine; before, the choice was dropped and chat rows ran with
    /// no pane to open in.
    @Test func aRowPickedWithNoWindowRunsOnceTheWindowsFirstPaneMounts() {
        let host = Host()
        host.dockMenuHasWindow = false
        let controller = DockMenuController(lanes: AgentLaneStore(), marks: AgentPriorityMarks(defaults: nil), host: host)
        controller.run(.newChat(harness: "codex", machine: nil))
        #expect(host.reopens == 1)
        #expect(host.newChats.isEmpty)
        #expect(controller.waiting == .newChat(harness: "codex", machine: nil))
        // A later pick replaces the waiting one.
        controller.run(.newChat(harness: nil, machine: "peer:m"))
        host.dockMenuHasWindow = true
        controller.windowDidShowContent()
        #expect(host.newChats == [["host": .string("peer:m")]])
        #expect(!controller.isWaiting)
        controller.windowDidShowContent() // runs once
        #expect(host.newChats.count == 1)

        host.dockMenuHasWindow = false
        controller.run(.open(chat: "a"))
        #expect(host.opened.isEmpty)
        host.dockMenuHasWindow = true
        controller.windowDidShowContent()
        #expect(host.opened == ["a"])
        controller.stop()
    }

    @Test func plainNewChatWithNoWindowUsesTheNewWindowsNewTabPage() {
        let host = Host()
        host.dockMenuHasWindow = false
        let controller = DockMenuController(lanes: AgentLaneStore(), marks: AgentPriorityMarks(defaults: nil), host: host)
        controller.run(.newChat(harness: nil, machine: nil))
        controller.windowDidShowContent()
        #expect(host.reopens == 1 && !controller.isWaiting && host.newChats.isEmpty)
        controller.stop()
    }

    @Test func aWaitingRowWaitsForAPaneInTheActiveWindow() {
        let host = Host()
        host.dockMenuHasWindow = false
        host.dockMenuHasPane = false
        let controller = DockMenuController(lanes: AgentLaneStore(), marks: AgentPriorityMarks(defaults: nil), host: host)
        controller.run(.open(chat: "a"))
        host.dockMenuHasWindow = true
        controller.windowDidShowContent() // a window, but its active window shows no pane yet
        #expect(host.opened.isEmpty && controller.isWaiting)
        host.dockMenuHasPane = true
        controller.windowDidShowContent()
        #expect(host.opened == ["a"] && !controller.isWaiting)
        controller.stop()
    }

    @Test func aPickWithAWindowOpenDropsAStaleWaitingPick() {
        let host = Host()
        host.dockMenuHasWindow = false
        let controller = DockMenuController(lanes: AgentLaneStore(), marks: AgentPriorityMarks(defaults: nil), host: host)
        controller.run(.open(chat: "stale"))
        host.dockMenuHasWindow = true
        controller.run(.open(chat: "b"))
        #expect(!controller.isWaiting)
        controller.windowDidShowContent() // a later first-pane mount runs nothing old
        #expect(host.opened == ["b"])
        controller.stop()
    }

    /// A closed window brought back mounts its panes inside the reopen call: the first-pane hook
    /// must already see the pick waiting, and the pick runs.
    @Test func aReopenThatMountsAtOnceStillRunsThePick() {
        let host = Host()
        host.dockMenuHasWindow = false
        host.dockMenuHasPane = false
        let controller = DockMenuController(lanes: AgentLaneStore(), marks: AgentPriorityMarks(defaults: nil), host: host)
        var hookSawWaiting = false
        host.onReopen = {
            host.dockMenuHasWindow = true
            host.dockMenuHasPane = true
            hookSawWaiting = controller.isWaiting // WorkspaceContentController's first mount
        }
        controller.run(.open(chat: "a"))
        #expect(hookSawWaiting)
        if hookSawWaiting { controller.windowDidShowContent() } // the hook's deferred call
        #expect(host.opened == ["a"])
        controller.stop()
    }

    /// The last window closed on a top page (History): it comes back with no pane mounted. A chat a
    /// tab already shows is revealed at once, as before, instead of waiting for a pane.
    @Test func aReopenedTopPageWindowRevealsAChatATabShows() {
        let host = Host()
        host.dockMenuHasWindow = false
        host.dockMenuHasPane = false
        host.shownChats = ["a"]
        let controller = DockMenuController(lanes: AgentLaneStore(), marks: AgentPriorityMarks(defaults: nil), host: host)
        host.onReopen = { host.dockMenuHasWindow = true }
        controller.run(.open(chat: "a"))
        #expect(host.opened == ["a"] && !controller.isWaiting)
        controller.stop()
    }

    @Test func aPlainNewChatDropsAWaitingPick() {
        let host = Host()
        host.dockMenuHasWindow = false
        host.dockMenuHasPane = false
        let controller = DockMenuController(lanes: AgentLaneStore(), marks: AgentPriorityMarks(defaults: nil), host: host)
        controller.run(.open(chat: "a"))
        controller.run(.newChat(harness: nil, machine: nil))
        #expect(!controller.isWaiting)
        controller.stop()
    }

    /// #33727: a terminal harness opens a terminal, not a chat, so New Chat in ▸ leaves it out.
    @Test func newChatInLeavesTerminalHarnessesOut() {
        let rows = [AcpmuxHarnessRow(id: "codex", kind: "acp", source: "path"),
                    AcpmuxHarnessRow(id: "shell", kind: "terminal", source: "user-file"),
                    AcpmuxHarnessRow(id: "claude", name: "Claude", kind: "claude-stdio", source: "path")]
        let choices = DockMenuChoices.make(harnesses: rows, machines: [AgentChatDestinations.local(title: "This Mac")])
        #expect(choices.harnesses.map(\.id) == ["claude", "codex"])
    }

    // MARK: Built when the menu opens (audit 2026-11-18 section 16)

    /// Leo, 2026-11-18: "Why should non visible thing even affect the renderer thread anyways?" The Dock menu is read
    /// on a right-click; its rows were rebuilt from every chat up to once a second while agents streamed. Detector: lane
    /// changes with the menu closed build nothing, and opening it builds once from the lanes as they are.
    @Test func laneChangesBuildNoRowsUntilTheMenuOpens() async {
        let host = Host()
        let lanes = AgentLaneStore()
        let controller = DockMenuController(lanes: lanes, marks: AgentPriorityMarks(defaults: nil), host: host)
        controller.start()
        for step in 1...50 {
            lanes.set("c\(step % 5)", Self.lane("c\(step % 5)", updated: TimeInterval(step)))
            await Task.yield()
        }
        // Longer than a detached build of five lanes takes: a build after a change would have landed.
        try? await Task.sleep(for: .milliseconds(300))
        let whileClosed = controller.builds
        print("dock-menu-detector lane_changes=50 builds_while_closed=\(whileClosed)")
        #expect(whileClosed == 0, "the Dock menu's rows were built \(whileClosed) times while nobody had it open")
        let menu = controller.menu()
        #expect(controller.builds == whileClosed + 1, "opening the menu builds its rows once")
        // Step 50 changed c0 last: Continue names it, with no wait for a rebuild.
        #expect(menu.items.contains { $0.title == DockMenuStrings.continueChat("Chat c0") })
        controller.stop()
    }

    /// 10,789 chats (Leo's Mac, 2026-11-18): one build, as a right-click now runs it, timed. The rows match a plain
    /// filter and sort of every chat (the build keeps only the few newest instead of sorting them all).
    @Test func buildingTheRowsOfTenThousandChatsIsQuickAndMatchesAFullSort() {
        let count = 10_789
        var lanes: [AgentActivityLane] = []
        lanes.reserveCapacity(count)
        for index in 0..<count {
            lanes.append(Self.lane("c\(index)", updated: TimeInterval((index &* 7919) % 4_000), unread: index % 3 == 0,
                                   hidden: index % 17 == 0))
        }
        var marks = AgentPriorityMarks.State()
        for index in stride(from: 0, to: count, by: 11) { marks.archived.insert("c\(index)") }
        for index in stride(from: 3, to: count, by: 13) { marks.read["c\(index)"] = AgentPriorityMarks.stamp(lanes[index]) }
        let now = Date(timeIntervalSince1970: 1_000_000)
        let clock = ContinuousClock()
        var made = DockMenuChats.empty
        let rounds = 10
        let elapsed = clock.measure {
            for _ in 0..<rounds { made = DockMenuChats.make(lanes: lanes, marks: marks, now: now) }
        }
        let milliseconds = Double(elapsed.components.attoseconds) / 1e15 / Double(rounds) + Double(elapsed.components.seconds) * 1000 / Double(rounds)
        print("dock-menu-bench chats=\(count) build_ms=\(String(format: "%.2f", milliseconds))")
        #expect(made == Self.reference(lanes: lanes, marks: marks, now: now))
        #expect(made.recentMore.count == 10 && made.unreadMore.count == 10)
    }

    /// Ties (equal times) and small lists give the same rows as a full sort too.
    @Test func theRowsMatchAFullSortOnTiesAndShortLists() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        for count in [0, 1, 2, 4, 7, 15, 40] {
            let lanes = (0..<count).map { Self.lane("t\($0)", updated: TimeInterval($0 % 3), unread: $0 % 2 == 0) }
            #expect(DockMenuChats.make(lanes: lanes, marks: .init(), now: now) == Self.reference(lanes: lanes, marks: .init(), now: now))
        }
    }

    /// The rows as a filter and full sort of every chat give them (the build before 2026-11-18).
    static func reference(lanes: [AgentActivityLane], marks: AgentPriorityMarks.State, now: Date, shown: Int = 3,
                          more: Int = 10) -> DockMenuChats {
        func changed(_ lane: AgentActivityLane) -> Date { lane.updatedAt ?? lane.since ?? lane.createdAt ?? .distantPast }
        func chat(_ lane: AgentActivityLane) -> DockMenuChats.Chat {
            .init(id: lane.id, title: DockMenuChats.title(lane.title.isEmpty ? lane.name : lane.title))
        }
        let listed = lanes.filter { lane in
            guard !lane.sidebarRequiresOpen, !marks.archived.contains(lane.id) else { return false }
            return !marks.isSnoozed(lane.id, stamp: AgentPriorityMarks.stamp(lane), now: now)
        }.sorted { a, b in changed(a) != changed(b) ? changed(a) > changed(b) : a.id < b.id }
        guard let first = listed.first else { return .empty }
        let unreadLanes = listed.filter { $0.unread && marks.read[$0.id] != AgentPriorityMarks.stamp($0) }
        let unread = unreadLanes.prefix(shown).map(chat)
        let shownUnread = Set(unread.map(\.id))
        let recentLanes = listed.dropFirst().filter { !shownUnread.contains($0.id) }
        return DockMenuChats(last: chat(first), unread: Array(unread), unreadMore: unreadLanes.dropFirst(shown).prefix(more).map(chat),
                             recent: recentLanes.prefix(shown).map(chat), recentMore: recentLanes.dropFirst(shown).prefix(more).map(chat))
    }
}
