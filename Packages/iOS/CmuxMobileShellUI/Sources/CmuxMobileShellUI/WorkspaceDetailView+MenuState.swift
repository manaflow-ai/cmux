import CmuxMobileShellModel

struct TerminalPickerMenuRow: Identifiable, Equatable {
    let id: MobileTerminalPreview.ID
    let name: String

    init(_ terminal: MobileTerminalPreview) {
        id = terminal.id
        name = terminal.name
    }
}

extension WorkspaceDetailView {
    var terminalPickerLiveRows: [TerminalPickerMenuRow] {
        workspace.terminals.map(TerminalPickerMenuRow.init)
    }

    var terminalPickerRowsForMenu: [TerminalPickerMenuRow] {
        terminalPickerRows.isEmpty ? terminalPickerLiveRows : terminalPickerRows
    }

    var terminalPickerSelectedID: MobileTerminalPreview.ID? {
        if let selectedID = store.selectedTerminalID,
           terminalPickerRowsForMenu.contains(where: { $0.id == selectedID }) {
            return selectedID
        }
        return terminalPickerRowsForMenu.first?.id
    }

    var terminalPickerSelectedName: String? {
        guard let terminalPickerSelectedID else { return nil }
        return terminalPickerRowsForMenu.first { $0.id == terminalPickerSelectedID }?.name
    }

    func syncTerminalPickerRows() {
        let rows = terminalPickerLiveRows
        guard terminalPickerRows != rows else { return }
        terminalPickerRows = rows
    }

    var hasTitleMenuActions: Bool {
        workspace.actionCapabilities.supportsWorkspaceActions
            || workspace.actionCapabilities.supportsReadStateActions
            || closeWorkspace != nil
    }
}
