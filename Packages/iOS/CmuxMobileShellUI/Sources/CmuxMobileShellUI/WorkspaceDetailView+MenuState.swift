import CmuxMobileShellModel

struct TerminalPickerMenuRow: Identifiable, Equatable {
    let id: MobileTerminalPreview.ID
    let name: String

    init(_ terminal: MobileTerminalPreview) {
        id = terminal.id
        name = terminal.name
    }
}

extension Collection where Element == TerminalPickerMenuRow {
    func resolvedTerminalPickerSelection(
        selectedID: MobileTerminalPreview.ID?
    ) -> (id: MobileTerminalPreview.ID, name: String)? {
        if let selectedID,
           let selected = first(where: { $0.id == selectedID }) {
            return (id: selected.id, name: selected.name)
        }
        guard let first else { return nil }
        return (id: first.id, name: first.name)
    }
}

extension WorkspaceDetailView {
    var terminalPickerLiveRows: [TerminalPickerMenuRow] {
        workspace.terminals.map(TerminalPickerMenuRow.init)
    }

    var terminalPickerLiveIDs: [MobileTerminalPreview.ID] {
        workspace.terminals.map(\.id)
    }

    var hasTitleMenuActions: Bool {
        workspace.actionCapabilities.supportsWorkspaceActions
            || workspace.actionCapabilities.supportsReadStateActions
            || closeWorkspace != nil
    }
}
