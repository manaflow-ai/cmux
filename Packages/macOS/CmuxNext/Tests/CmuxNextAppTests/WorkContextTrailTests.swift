@testable import CmuxNextApp
import Testing

/// NEW-WORK-INHERITS-CONTEXT: a new terminal or agent chat copies the terminal or chat the person
/// focused last, in its workspace, then (for a workspace with none of its own) in its window.
struct WorkContextTrailTests {
    typealias Entry = WorkContextTrail.Entry

    static func terminal(_ tab: String, _ workspace: String = "w1", window: String = "win1") -> Entry {
        Entry(tab: tab, workspace: workspace, window: window, kind: .terminal)
    }

    static func chat(_ tab: String, _ workspace: String = "w1", window: String = "win1") -> Entry {
        Entry(tab: tab, workspace: workspace, window: window, kind: .chat)
    }

    /// Each tab's folder, as a live lookup would read it.
    static let folders = ["t1": "/repo/a", "t2": "/repo/b", "c1": "/repo/chat", "t9": "/other/x", "tw": "/win2/y"]

    func resolve(_ trail: WorkContextTrail, current: Entry? = nil, workspace: String = "w1", window: String = "win1",
                 hasWork: Bool = true, kinds: Set<WorkContextTrail.Kind> = [.terminal, .chat],
                 folders: [String: String] = Self.folders) -> String? {
        trail.resolve(current: current, workspace: workspace, window: window, workspaceHasWork: hasWork, kinds: kinds) { folders[$0.tab] }
    }

    @Test func theNewestFocusedTerminalOrChatOfTheWorkspaceWins() {
        var trail = WorkContextTrail()
        trail.record(Self.terminal("t1"))
        trail.record(Self.chat("c1"))
        #expect(resolve(trail) == "/repo/chat")
        trail.record(Self.terminal("t2"))
        #expect(resolve(trail) == "/repo/b")
        // Focusing an older tab again makes it the newest.
        trail.record(Self.terminal("t1"))
        #expect(resolve(trail) == "/repo/a")
    }

    @Test func theTabThePersonIsInWinsOverTheTrail() {
        var trail = WorkContextTrail()
        trail.record(Self.terminal("t2"))
        #expect(resolve(trail, current: Self.chat("c1")) == "/repo/chat")
    }

    @Test func aClosedOrFolderlessTabIsSkipped() {
        var trail = WorkContextTrail()
        trail.record(Self.terminal("t1"))
        trail.record(Self.terminal("gone"))
        #expect(resolve(trail) == "/repo/a")
        trail.record(Self.terminal("t2"))
        trail.forget(tab: "t2")
        #expect(resolve(trail) == "/repo/a")
        #expect(!trail.entries.contains { $0.tab == "t2" })
    }

    @Test func anotherWorkspaceIsNoSourceWhileTheWorkspaceHasItsOwnWork() {
        var trail = WorkContextTrail()
        trail.record(Self.terminal("t1"))
        trail.record(Self.terminal("t9", "w2"))
        // w1's own terminal, though w2's was focused later.
        #expect(resolve(trail) == "/repo/a")
        // A workspace with terminals nobody focused yet keeps them (the caller's resolver picks).
        #expect(resolve(trail, workspace: "w3", hasWork: true) == nil)
    }

    @Test func aWorkspaceWithNoWorkOfItsOwnTakesTheWindowsNewest() {
        var trail = WorkContextTrail()
        trail.record(Self.terminal("t1"))
        trail.record(Self.terminal("tw", "w5", window: "win2"))
        // Another window's newer terminal is never a source.
        #expect(resolve(trail, workspace: "w3", hasWork: false) == "/repo/a")
        #expect(resolve(trail, workspace: "w3", window: "win3", hasWork: false) == nil)
    }

    @Test func chatSettingsComeOnlyFromChats() {
        var trail = WorkContextTrail()
        trail.record(Self.chat("c1"))
        trail.record(Self.terminal("t1"))
        #expect(resolve(trail, current: Self.terminal("t2"), kinds: [.chat]) == "/repo/chat")
    }

    @Test func theTrailKeepsOneEntryPerTabUpToItsLimit() {
        var trail = WorkContextTrail()
        for index in 0..<(WorkContextTrail.limit + 10) { trail.record(Self.terminal("t\(index)")) }
        trail.record(Self.terminal("t\(WorkContextTrail.limit + 9)"))
        #expect(trail.entries.count == WorkContextTrail.limit)
        #expect(trail.entries.first?.tab == "t\(WorkContextTrail.limit + 9)")
        #expect(Set(trail.entries.map(\.tab)).count == WorkContextTrail.limit)
    }
}
