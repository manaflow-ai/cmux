@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextLayout
import Testing

/// Main pane layout (`layout.mainPane`, Leo 2026-10-20): an agent chat is its screen's one main
/// pane and nothing opens into it. What it opens is a tab in the column on its right, the way a
/// person's new tab from the chat dock opens; a chat alone on its screen docks left first. Any
/// other pane keeps the usual rules.
@MainActor
struct MainPaneLayoutTests {
    private static let chatDock = DockColumn(edge: .left, role: .agentChat)
    private static let lone: @Sendable (LayoutColumn) -> Bool = { $0.id == "chat" }

    @Test func theDebugOverrideWinsOverTheSetting() {
        #expect(MainPaneLayout.isOn(setting: true, override: .setting))
        #expect(!MainPaneLayout.isOn(setting: false, override: .setting))
        #expect(MainPaneLayout.isOn(setting: false, override: .on))
        #expect(!MainPaneLayout.isOn(setting: true, override: .off))
        #expect(MainPaneLayout.debugOverride.defaultValue == .setting, "the setting decides unless Debug Settings says otherwise")
    }

    /// A chat alone on its screen docks left, and what it opened stays in its pane, on the right.
    @Test func aLoneChatDocksSoWhatItOpensSlidesInOnItsRight() {
        let columns = [LayoutColumn(id: "chat", root: .leaf("c"))]
        #expect(MainPaneLayout.side(from: "c", columns: columns, isLoneChat: Self.lone) == .dockChat)
    }

    /// Beside the chat dock, every open is a tab in the strip: in the pane the person used last,
    /// else the first one, never in the chat.
    @Test func besideTheChatDockOpensAreTabsOnTheRight() {
        let columns = [LayoutColumn(id: "dock", root: .leaf("c"), dock: Self.chatDock),
                       LayoutColumn(id: "right", root: .leaf("r1")), LayoutColumn(id: "more", root: .leaf("r2"))]
        #expect(MainPaneLayout.side(from: "c", columns: columns, isLoneChat: Self.lone) == .tab(in: "r1"))
        #expect(MainPaneLayout.side(from: "c", columns: columns, recent: ["c", "r2", "r1"], isLoneChat: Self.lone) == .tab(in: "r2"))
    }

    /// Only the chat is a main pane: a pane in the strip, a terminal alone, a chat sharing its screen
    /// with other columns and not docked, and a zoomed screen keep the usual rules.
    @Test func otherPanesKeepTheUsualRules() {
        let docked = [LayoutColumn(id: "dock", root: .leaf("c"), dock: Self.chatDock), LayoutColumn(id: "right", root: .leaf("r1"))]
        #expect(MainPaneLayout.side(from: "r1", columns: docked, isLoneChat: Self.lone) == nil)
        let terminal = [LayoutColumn(id: "term", root: .leaf("t"))]
        #expect(MainPaneLayout.side(from: "t", columns: terminal, isLoneChat: Self.lone) == nil)
        let shared = [LayoutColumn(id: "chat", root: .leaf("c")), LayoutColumn(id: "term", root: .leaf("t"))]
        #expect(MainPaneLayout.side(from: "c", columns: shared, isLoneChat: Self.lone) == nil)
        let alone = [LayoutColumn(id: "chat", root: .leaf("c"))]
        #expect(MainPaneLayout.side(from: "c", columns: alone, zoomed: true, isLoneChat: Self.lone) == nil)
    }

    /// Home's pinned dock alone already opens beside itself (`pinned-dock-alone-v1`); with a column
    /// beside it, its opens are tabs there like any chat dock's.
    @Test func homesPinnedDockOpensBesideItself() {
        let home = LayoutColumn(id: "home", root: .leaf("h"), dock: DockColumn(edge: .left, role: .agentChat, isPinned: true))
        #expect(MainPaneLayout.side(from: "h", columns: [home], isLoneChat: Self.lone) == nil)
        #expect(MainPaneLayout.side(from: "h", columns: [home, LayoutColumn(id: "right", root: .leaf("r1"))],
                                    isLoneChat: Self.lone) == .tab(in: "r1"))
    }

    /// The Debug override is listed, so Debug Settings shows it and `debug.tunables` can set it.
    @Test func theOverrideIsInDebugSettings() {
        #expect(TunableCatalog.all.contains { $0.key == MainPaneLayout.debugOverride.key })
    }
}
