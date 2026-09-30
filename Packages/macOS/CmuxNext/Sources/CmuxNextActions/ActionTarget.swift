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

/// Surfaces with a right-click menu. Each has an ordered list of action IDs
/// in `ContextMenuCatalog`; the registry renders them.
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
    /// A tab strip's new tab (+) button: which kind of tab to open.
    case newTab
    /// A room dot in the sidebar.
    case profile

    /// The object a right-click in this context targets, if any.
    public var targetKind: ActionTargetKind? {
        switch self {
        case .tab: .tab
        case .tabGroup: .tabGroup
        case .screen: .screen
        case .screenGroup: .screenGroup
        case .pane, .terminalSelection, .browserPage, .link, .newTab: .pane
        case .column: .column
        case .workspaceRow: .workspace
        case .workspaceGroup: .workspaceGroup
        case .sidebarBackground: nil
        case .cloudMachine: .machine
        case .profile: .profile
        }
    }
}
