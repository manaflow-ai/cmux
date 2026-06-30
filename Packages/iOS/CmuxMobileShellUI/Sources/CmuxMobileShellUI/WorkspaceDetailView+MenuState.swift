import CmuxMobileShellModel

struct TerminalPickerMenuRow: Identifiable, Equatable {
    let id: MobileTerminalPreview.ID
    let name: String

    init(_ terminal: MobileTerminalPreview) {
        id = terminal.id
        name = terminal.name
    }
}

struct TerminalPickerMenuSelection: Equatable {
    let id: MobileTerminalPreview.ID
    let name: String

    static func resolve(
        rows: [TerminalPickerMenuRow],
        selectedID: MobileTerminalPreview.ID?
    ) -> TerminalPickerMenuSelection? {
        if let selectedID,
           let selected = rows.first(where: { $0.id == selectedID }) {
            return TerminalPickerMenuSelection(id: selected.id, name: selected.name)
        }
        guard let first = rows.first else { return nil }
        return TerminalPickerMenuSelection(id: first.id, name: first.name)
    }
}

extension WorkspaceDetailView {
    var terminalPickerLiveRows: [TerminalPickerMenuRow] {
        workspace.terminals.map(TerminalPickerMenuRow.init)
    }

    var hasTitleMenuActions: Bool {
        workspace.actionCapabilities.supportsWorkspaceActions
            || workspace.actionCapabilities.supportsReadStateActions
            || closeWorkspace != nil
    }
}
