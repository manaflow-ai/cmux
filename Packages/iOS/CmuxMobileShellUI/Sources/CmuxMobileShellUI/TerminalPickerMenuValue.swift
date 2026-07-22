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

    var terminalRows: [TerminalPickerMenuRow] {
        rows.filter { if case .terminal = $0.id { true } else { false } }
    }

    var macSurfaceRows: [TerminalPickerMenuRow] {
        rows.filter { if case .macSurface = $0.id { true } else { false } }
    }
}
