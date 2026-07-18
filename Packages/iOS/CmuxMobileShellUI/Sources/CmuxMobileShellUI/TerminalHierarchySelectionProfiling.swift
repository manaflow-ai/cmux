import CmuxMobileShellModel

enum TerminalHierarchyProfilingSelectionKind: Equatable {
    case terminalSwitch
    case paneSwitch
}

extension TerminalHierarchySnapshot {
    func profilingSelectionKind(
        for terminalID: MobileTerminalPreview.ID
    ) -> TerminalHierarchyProfilingSelectionKind? {
        guard let targetPane = panes.first(where: { pane in
            pane.rows.contains(where: { $0.id == terminalID })
        }),
        !targetPane.rows.contains(where: { $0.id == terminalID && $0.isSelected }) else {
            return nil
        }
        let activePaneID = panes.first(where: { pane in
            pane.rows.contains(where: \.isSelected)
        })?.id ?? panes.first(where: \.isFocused)?.id
        guard let activePaneID else { return .terminalSwitch }
        return activePaneID == targetPane.id ? .terminalSwitch : .paneSwitch
    }
}
