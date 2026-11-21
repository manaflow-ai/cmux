/// Some tabs of one workspace, by identity: the item of a per-workspace observation (`ObservedItemsFeed`) whose
/// consumer needs the tab records, as the browser host's announced tabs. Equal when the same records are listed in
/// the same order, so a tab of another kind that comes or goes changes nothing.
public nonisolated struct WorkspaceTabs: Equatable, Sendable {
    /// The workspace's id.
    public let workspace: String
    public let tabs: [TabModel]

    public static func == (a: Self, b: Self) -> Bool {
        a.workspace == b.workspace && a.tabs.elementsEqual(b.tabs) { $0 === $1 }
    }
}

extension WorkspaceModel {
    /// This workspace's tabs of `kind` in screen, pane and tab order (none when `hidden`). Reads this workspace's
    /// screens, panes and tabs only.
    public func tabs(of kind: TabKind, hidden: Bool = false) -> WorkspaceTabs {
        WorkspaceTabs(workspace: id, tabs: hidden ? [] : screens.flatMap(\.panes).flatMap(\.tabs).filter { $0.kind == kind })
    }
}
