/// Kinds of objects an action can act on or take as an argument. Raw values
/// are the CLI's `--target <kind>:<id>` prefixes.
public nonisolated enum ActionTargetKind: String, CaseIterable, Sendable, Hashable, Codable {
    case tab
    case tabGroup = "tab-group"
    case pane
    case column
    case screen
    case screenGroup = "screen-group"
    case workspace
    case workspaceGroup = "workspace-group"
    case window
    /// A Cloud machine (`machine:vm-…`); the local daemon is `machine:local`.
    case machine
    /// A room (`room:default`, `room:prof_…`; plans/cmux-next/data-model.md;
    /// the daemon calls rooms profiles).
    case profile = "room"
    /// A browser profile (`browser-profile:default`, `browser-profile:<uuid>`;
    /// plans/cmux-next/data-model.md section 5).
    case browserProfile = "browser-profile"
    /// A bookmark or bookmark folder (`bookmark:bm_…`; plans/cmux-next/bookmarks.md).
    case bookmark
}

extension ActionTargetKind {
    /// The kinds an object of this kind names by containment: a tab names
    /// its pane, column, screen and workspace. A right-click on a tab
    /// therefore reaches actions on its pane.
    public nonisolated var containers: [ActionTargetKind] {
        switch self {
        case .tab: [.pane, .column, .screen, .workspace]
        case .pane: [.column, .screen, .workspace]
        case .column: [.screen, .workspace]
        case .screen, .tabGroup: [.workspace]
        default: []
        }
    }
}

/// A reference to one object: what the user right-clicked, what the CLI
/// named with `--target`, or what the palette picked.
public nonisolated struct ActionTargetRef: Sendable, Hashable, Codable, CustomStringConvertible {
    public let kind: ActionTargetKind
    public let id: String

    public init(kind: ActionTargetKind, id: String) {
        self.kind = kind
        self.id = id
    }

    /// Parses the CLI form `kind:id`.
    public init?(parsing text: String) {
        guard let colon = text.firstIndex(of: ":"),
              let kind = ActionTargetKind(rawValue: String(text[..<colon]))
        else { return nil }
        let id = String(text[text.index(after: colon)...])
        guard !id.isEmpty else { return nil }
        self.init(kind: kind, id: id)
    }

    public var description: String { "\(kind.rawValue):\(id)" }
}

/// Surfaces with a right-click menu. `ContextMenuCatalog` generates each
/// from the actions' placements; the registry renders them.
public nonisolated enum ActionMenuContext: String, CaseIterable, Sendable, Hashable, Codable {
    case tab
    case tabGroup
    /// A screen tab in the workspace's screen bar.
    case screen
    /// A screen group chip in the screen bar.
    case screenGroup
    case pane
    case column
    case workspaceRow
    case workspaceGroup
    case sidebarBackground
    case terminalSelection
    case browserPage
    case link
    /// A Cloud machine's sidebar section header.
    case cloudMachine
    /// An SSH machine's sidebar section header.
    case sshMachine
    /// A tab strip's new tab (+) button: which kind of tab to open.
    case newTab
    /// A room dot in the sidebar.
    case profile
    /// A browser profile (the omnibar's profile badge, a Settings row).
    case browserProfile
    /// A bookmark or folder on the bookmarks bar.
    case bookmark
    /// The bookmarks bar's empty area.
    case bookmarksBar
    /// The screen bar's empty area or its new screen (+) button.
    case screenBar
    /// A row of the notifications panel.
    case notification

    /// The object a right-click in this context targets, if any.
    public var targetKind: ActionTargetKind? {
        switch self {
        case .tab: .tab
        case .tabGroup: .tabGroup
        case .screen: .screen
        case .screenGroup: .screenGroup
        // A terminal or page right-click targets its tab (the App passes the
        // tab; a tab names its pane).
        case .terminalSelection, .browserPage, .link: .tab
        case .pane, .newTab: .pane
        case .column: .column
        case .workspaceRow: .workspace
        case .workspaceGroup: .workspaceGroup
        case .sidebarBackground: nil
        case .cloudMachine, .sshMachine: .machine
        case .profile: .profile
        case .browserProfile: .browserProfile
        case .bookmark: .bookmark
        case .bookmarksBar, .screenBar, .notification: nil
        }
    }
}
