import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSupport

/// Immutable state that determines the native terminal picker's presented menu.
struct TerminalPickerMenuValue: Equatable {
    let rows: [TerminalPickerMenuRow]
    let selectedID: MobileTerminalPreview.ID?
    let selectedMacSurfaceID: MobileSurfacePreview.ID?
    let selectedName: String?
    let canCreateWorkspace: Bool
    /// False for workspaces without terminal tabs (plain SSH shells).
    let canCreateTerminal: Bool
    let hasActiveBrowser: Bool
    let browserStreamRows: [BrowserStreamPickerRow]
    let supportsBrowserStream: Bool
    let activeBrowserStreamPanelID: String?
    /// The streamed tab the phone-local browser shows "On iPhone", if any.
    let onDeviceBrowserStreamPanelID: String?
    let simulatorStreamRows: [SimulatorStreamPickerRow]
    let supportsSimulatorStream: Bool
    let activeSimulatorStreamPanelID: String?
    /// SSH tmux and cmux-tui workspaces: terminals grouped by tmux window or
    /// cmux-tui screen (PRD D32). `nil` keeps the flat Terminals section
    /// (Mac workspaces, shells).
    let sshTabLayout: MobileSSHTabLayout?
    /// Whether the workspace belongs to an SSH computer rather than a cmux
    /// Mac, which names its browser section.
    let isSSHComputer: Bool

    init(
        liveTerminals: [MobileTerminalPreview],
        liveSurfaces: [MobileSurfacePreview] = [],
        snapshotRows: [TerminalPickerMenuRow],
        selectedID: MobileTerminalPreview.ID?,
        selectedMacSurfaceID: MobileSurfacePreview.ID? = nil,
        canCreateWorkspace: Bool,
        canCreateTerminal: Bool = true,
        hasActiveBrowser: Bool,
        browserStreamRows: [BrowserStreamPickerRow] = [],
        supportsBrowserStream: Bool = false,
        activeBrowserStreamPanelID: String? = nil,
        onDeviceBrowserStreamPanelID: String? = nil,
        simulatorStreamRows: [SimulatorStreamPickerRow] = [],
        supportsSimulatorStream: Bool = false,
        activeSimulatorStreamPanelID: String? = nil,
        sshTabLayout: MobileSSHTabLayout? = nil,
        isSSHComputer: Bool = false
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
        self.canCreateTerminal = canCreateTerminal
        self.hasActiveBrowser = hasActiveBrowser
        self.browserStreamRows = browserStreamRows
        self.supportsBrowserStream = supportsBrowserStream
        self.activeBrowserStreamPanelID = activeBrowserStreamPanelID
        self.onDeviceBrowserStreamPanelID = onDeviceBrowserStreamPanelID
        self.simulatorStreamRows = simulatorStreamRows
        self.supportsSimulatorStream = supportsSimulatorStream
        self.activeSimulatorStreamPanelID = activeSimulatorStreamPanelID
        self.sshTabLayout = sshTabLayout
        self.isSSHComputer = isSSHComputer
    }

    /// The streamed-browser section's title, by the kind of computer the
    /// tabs run on: "Mac Browsers" for a cmux Mac, "Browsers" for an SSH
    /// computer (its tabs are not on a Mac).
    var browserSectionTitle: String {
        isSSHComputer
            ? L10n.string("mobile.ssh.browserStream.menuTitle", defaultValue: "Browsers")
            : L10n.string("mobile.browserStream.menuTitle", defaultValue: "Mac Browsers")
    }

    /// The single row that carries the checkmark. Nil while the phone-local
    /// browser or a Mac browser stream overlays the workspace (the stream row
    /// draws its own check from `checkedBrowserStreamPanelID`); a Mac-surface
    /// selection whose row has disappeared falls back to the resolved
    /// terminal, matching `selectedName`.
    var checkedRowID: TerminalPickerMenuRow.ID? {
        if hasActiveBrowser || activeBrowserStreamPanelID != nil || activeSimulatorStreamPanelID != nil { return nil }
        if let selectedMacSurfaceID,
           rows.contains(where: { $0.id == .macSurface(selectedMacSurfaceID) }) {
            return .macSurface(selectedMacSurfaceID)
        }
        return selectedID.map(TerminalPickerMenuRow.ID.terminal)
    }

    /// The Mac Browsers row that carries the checkmark: the streamed tab on
    /// screen, in either mode. "On iPhone" shows the tab through the
    /// phone-local browser, but it is still that tab.
    var checkedBrowserStreamPanelID: String? {
        if let activeBrowserStreamPanelID { return activeBrowserStreamPanelID }
        guard hasActiveBrowser, let onDeviceBrowserStreamPanelID,
              browserStreamRows.contains(where: { $0.id == onDeviceBrowserStreamPanelID }) else { return nil }
        return onDeviceBrowserStreamPanelID
    }

    /// Whether "New Browser" carries the checkmark: a phone-local browser is
    /// up and it is not a streamed tab shown "On iPhone".
    var checksNewBrowser: Bool {
        hasActiveBrowser && checkedBrowserStreamPanelID == nil
    }

    var terminalRows: [TerminalPickerMenuRow] {
        rows.filter { if case .terminal = $0.id { true } else { false } }
    }

    /// Mac-surface rows for the "Mac Surfaces" section. Browser panes are
    /// excluded whenever the Mac supports browser streaming — they get their
    /// own "Mac Browsers" section — and only fall back to a surface row on
    /// Macs without streaming. Filtered here (not at row construction) so
    /// snapshot-built rows obey the same policy as live ones.
    var macSurfaceRows: [TerminalPickerMenuRow] {
        rows.filter {
            guard case .macSurface = $0.id else { return false }
            return !(supportsBrowserStream && $0.surfaceKind == .browser)
        }
    }
}
