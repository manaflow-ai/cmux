import CmuxMobileShellModel

struct TerminalPickerMenuRow: Identifiable, Equatable {
    let id: MobileTerminalPreview.ID
    let name: String

    init(_ terminal: MobileTerminalPreview) {
        id = terminal.id
        name = terminal.name
    }
}

/// Structural change token for the native menu; title churn must not rebuild an open picker.
struct TerminalPickerMenuMembership: Equatable {
    let ids: [MobileTerminalPreview.ID]

    init(_ rows: [TerminalPickerMenuRow]) {
        ids = rows.map(\.id)
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

    var terminalPickerLiveMembership: TerminalPickerMenuMembership {
        TerminalPickerMenuMembership(terminalPickerLiveRows)
    }

    func syncTerminalPickerRows(includeTitleChanges: Bool = false) {
        let rows = terminalPickerLiveRows
        if includeTitleChanges {
            guard terminalPickerRows != rows else { return }
            terminalPickerRows = rows
            return
        }
        guard terminalPickerRows.isEmpty
            || TerminalPickerMenuMembership(terminalPickerRows) != TerminalPickerMenuMembership(rows)
        else { return }
        terminalPickerRows = rows
    }

    var hasTitleMenuActions: Bool {
        workspace.actionCapabilities.supportsWorkspaceActions
            || workspace.actionCapabilities.supportsReadStateActions
            || closeWorkspace != nil
    }
}
