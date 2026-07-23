import CmuxMobileShellModel

/// Immutable state that determines the native terminal picker's presented menu.
struct TerminalPickerMenuValue: Equatable {
    let rows: [TerminalPickerMenuRow]
    let selectedID: MobileTerminalPreview.ID?
    let selectedMacSurfaceID: MobileSurfacePreview.ID?
    let selectedName: String?
    let canCreateWorkspace: Bool
    let hasActiveBrowser: Bool
    let isChatMode: Bool

    init(
        liveTerminals: [MobileTerminalPreview],
        liveSurfaces: [MobileSurfacePreview] = [],
        snapshotRows: [TerminalPickerMenuRow],
        selectedID: MobileTerminalPreview.ID?,
        selectedMacSurfaceID: MobileSurfacePreview.ID? = nil,
        canCreateWorkspace: Bool,
        hasActiveBrowser: Bool,
        isChatMode: Bool
    ) {
        let resolvedRows = snapshotRows.isEmpty
            ? liveTerminals.map(TerminalPickerMenuRow.init)
                + liveSurfaces.filter { !$0.kind.isTerminal }.map(TerminalPickerMenuRow.init)
            : snapshotRows
        rows = resolvedRows
        let selection = resolvedRows.resolvedTerminalPickerSelection(selectedID: selectedID)
        self.selectedID = selection?.id
        self.selectedMacSurfaceID = selectedMacSurfaceID
        selectedName = selectedMacSurfaceID.flatMap { id in
            resolvedRows.first(where: { $0.id == .macSurface(id) })?.name
        } ?? selection?.name
        self.canCreateWorkspace = canCreateWorkspace
        self.hasActiveBrowser = hasActiveBrowser
        self.isChatMode = isChatMode
    }

    /// The single row that carries the checkmark. Nil while the phone-local
    /// browser overlays the workspace; a Mac-surface selection whose row has
    /// disappeared falls back to the resolved terminal, matching
    /// `selectedName`.
    var checkedRowID: TerminalPickerMenuRow.ID? {
        if hasActiveBrowser { return nil }
        if let selectedMacSurfaceID,
           rows.contains(where: { $0.id == .macSurface(selectedMacSurfaceID) }) {
            return .macSurface(selectedMacSurfaceID)
        }
        return selectedID.map(TerminalPickerMenuRow.ID.terminal)
    }

    var terminalRows: [TerminalPickerMenuRow] {
        rows.filter { if case .terminal = $0.id { true } else { false } }
    }

    var macSurfaceRows: [TerminalPickerMenuRow] {
        rows.filter { if case .macSurface = $0.id { true } else { false } }
    }
}
