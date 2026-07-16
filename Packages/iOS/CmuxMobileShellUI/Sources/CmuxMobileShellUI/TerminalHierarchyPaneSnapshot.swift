import CmuxMobileShellModel

struct TerminalHierarchyPaneSnapshot: Identifiable, Equatable {
    let id: MobilePanePreview.ID
    let spatialIndex: Int
    let isFocused: Bool
    let rows: [TerminalHierarchyRowSnapshot]
    let pane: MobilePanePreview
}
