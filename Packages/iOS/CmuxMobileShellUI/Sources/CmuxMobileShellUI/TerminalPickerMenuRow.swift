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

    var terminalPickerSelectedName: String? {
        terminalPickerRowsForMenu.first { $0.id == store.selectedTerminalID }?.name
    }

    func syncTerminalPickerRows() {
        let rows = terminalPickerLiveRows
        guard terminalPickerRows != rows else { return }
        terminalPickerRows = rows
    }
}
