public import CmuxNextDesign

/// Main pane layout (`layout.mainPane`, Leo 2026-10-20): a screen's agent chat is its one main
/// pane, which nothing opens into. What the chat opens is a tab in the column on its right, the
/// way a person's new tab from the chat dock already opens (``ChatColumnPlacement``): in the strip
/// beside the chat dock, or, for a chat alone on its screen, the chat docks left and the tab stays
/// in its pane, which slides in on the right. When that column's last tab closes, the daemon folds
/// the dock back into a plain pane, so the chat has the whole width again.
public nonisolated struct MainPaneLayout {
    public nonisolated init() {}
    /// Debug Settings' override of `layout.mainPane`.
    public static let debugOverride = Tunable<MainPaneOverride>.choice(
        "panes.mainPane", .panes, "Main pane layout",
        help: "An agent chat is its screen's main pane: what it opens (links, files, subagents, side chats) is a tab in the column on its right. \"Follow the setting\" uses layout.mainPane in cmux.json; On and Off override it.",
        default: .setting, code: "MainPaneLayout.debugOverride")

    /// Whether main pane layout is on: the Debug override, else the setting (`agentChats`).
    public static func isOn(setting: Bool, override: MainPaneOverride) -> Bool {
        switch override {
        case .setting: setting
        case .on: true
        case .off: false
        }
    }

    /// Where what `pane` opens goes in main pane layout: a tab in the strip pane right of the chat
    /// dock (``ChatColumnPlacement/tab(in:)``), or the lone chat docks left and the tab stays in its
    /// pane (``ChatColumnPlacement/dockChat``). Nil when `pane` is not a main pane (not the chat
    /// dock, not a chat alone on its screen, a zoomed screen, or Home's pinned dock alone, which
    /// opens beside itself already): the usual rules apply. Arguments are
    /// ``ChatColumnPlacement/resolve(from:columns:recent:zoomed:isLoneChat:)``'s.
    public static func side(from pane: PaneID, columns: [LayoutColumn], recent: [PaneID] = [], zoomed: Bool = false,
                            isLoneChat: (LayoutColumn) -> Bool) -> ChatColumnPlacement? {
        side(of: ChatColumnPlacement.resolve(from: pane, columns: columns, recent: recent, zoomed: zoomed, isLoneChat: isLoneChat))
    }

    /// `placement` when it puts the new tab beside the chat, else nil.
    public static func side(of placement: ChatColumnPlacement) -> ChatColumnPlacement? {
        switch placement {
        case .tab, .dockChat: return placement
        case .here, .besideDock: return nil
        }
    }

    static var all: [TunableDescriptor] { [debugOverride.descriptor] }
}

/// Debug Settings' choice for ``MainPaneLayout/debugOverride``.
public nonisolated enum MainPaneOverride: String, Sendable, CaseIterable, TunableChoice {
    /// Follow `layout.mainPane` in cmux.json.
    case setting
    /// Main pane layout on, whatever cmux.json says.
    case on
    /// Main pane layout off, whatever cmux.json says.
    case off

    public var tunableTitle: String {
        switch self {
        case .setting: "Follow the setting"
        case .on: "On"
        case .off: "Off"
        }
    }
}
