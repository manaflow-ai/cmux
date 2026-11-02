import Foundation

/// One screen of a workspace on the Mac (cmux-tui `screens[]`): the Mac's screen bar shows each
/// one as a tab of its own, with its own panes and tabs. The phone lists every screen's tabs
/// together and marks each tab's screen; the Screens page switches, adds, renames and closes them.
public struct MacScreen: Identifiable, Hashable, Sendable, Codable {
    /// The daemon's screen id (`select`, `rename-screen`, `close-screen` name it).
    public var id: Int
    /// The Mac's name for it; empty: the Mac shows "Screen <n>".
    public var name: String
    /// The daemon's active screen of the workspace: where a new tab from the phone opens.
    public var isActive: Bool
    /// The screen's active pane (`active_pane`), which switching to the screen focuses.
    public var activePane: Int?
    /// Its panes, in layout order.
    public var panes: [Int]
    /// The tabs the phone lists on it, in pane and tab order.
    public var tabIDs: [String]

    public init(id: Int, name: String = "", isActive: Bool = false, activePane: Int? = nil, panes: [Int] = [], tabIDs: [String] = []) {
        self.id = id
        self.name = name
        self.isActive = isActive
        self.activePane = activePane
        self.panes = panes
        self.tabIDs = tabIDs
    }

    /// The Mac's title at `index` (0-based) in the bar: its name, else "Screen <n>" (`ScreenStrings.untitled`).
    public func title(at index: Int) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Screen \(index + 1)" : trimmed
    }
}

extension Workspace {
    /// The screen holding `tabID` and its place in the bar, when the Mac listed screens.
    public func screen(ofTab tabID: String) -> (screen: MacScreen, index: Int)? {
        guard let index = screens.firstIndex(where: { $0.tabIDs.contains(tabID) }) else { return nil }
        return (screens[index], index)
    }

    /// The tab's screen title for its card ("Screen 2"), only when the workspace has more than one screen.
    public func screenLabel(ofTab tabID: String) -> String? {
        guard screens.count > 1, let (screen, index) = screen(ofTab: tabID) else { return nil }
        return screen.title(at: index)
    }
}
