import CmuxMobileBrowser
import CmuxMobileShell
import CmuxMobileSupport
import SwiftUI
#if os(iOS)
import CmuxMobileBrowserStream
#endif

extension WorkspaceDetailView {
    /// The SSH computer behind this workspace, or `nil` for Mac workspaces.
    var sshHostID: UUID? {
        let computers = store.sshComputers
        return workspace.macDeviceID.flatMap(computers.hostID(forIdentifier:))
            ?? computers.hostID(forIdentifier: workspace.id.rawValue)
    }

    /// In an SSH workspace, the native ("On iPhone") browser browses through
    /// the computer: a SOCKS proxy for every address (DNS on the server) and
    /// the computer's loopback ports mirrored onto the phone's, in a data
    /// store private to that computer.
    var sshBrowserRoute: BrowserServerRoute? {
        guard let hostID = sshHostID else { return nil }
        let computers = store.sshComputers
        return BrowserServerRoute.route(id: hostID.uuidString) { loopbackPort in
            try await computers.prepareBrowserNetwork(hostID: hostID, loopbackPort: loopbackPort)
        }
    }

    /// The paired Mac behind this workspace, or `nil` for SSH workspaces.
    var browserTunnelMacID: String? {
        guard sshHostID == nil else { return nil }
        return workspace.macDeviceID ?? store.connectedMacDeviceID
    }

    /// In a Mac workspace whose Mac serves the browser tunnel, the native
    /// ("On iPhone") browser loads through the Mac: its `localhost` ports are
    /// mirrored onto the phone's, `*.localhost` names go through a SOCKS
    /// proxy to the Mac, and other hosts go through the Mac only when the Mac
    /// allows it (otherwise over the phone's own network). One data store per
    /// Mac.
    var macBrowserRoute: BrowserServerRoute? {
        guard let macID = browserTunnelMacID,
              store.macBrowserTunnelAvailability(macDeviceID: macID).bindsBrowserToMac else { return nil }
        let store = store
        return BrowserServerRoute.route(id: "mac:\(macID)") { loopbackPort in
            try await store.prepareMacBrowserNetwork(macDeviceID: macID, loopbackPort: loopbackPort)
        }
    }

    /// The computer the native browser loads through, if any.
    var browserServerRoute: BrowserServerRoute? {
        sshBrowserRoute ?? macBrowserRoute
    }
}

#if os(iOS)
/// The Streamed / On iPhone switch, for SSH workspaces and for Mac
/// workspaces. On a Mac that cannot serve "On iPhone" the row stays visible
/// but dimmed with the reason (an older cmux, or a connection without
/// tunnel lanes).
extension WorkspaceDetailView {
    private var streamedUnavailableReason: String {
        L10n.string(
            "mobile.browser.mode.streamed.unavailable",
            defaultValue: "Needs cmux Browser running on the computer"
        )
    }

    /// The switch on the native browser: back to its streamed tab (or the
    /// computer's first tab), unavailable when the computer has none.
    func onDeviceModePicker(_ browser: BrowserSurfaceState) -> MobileBrowserModePicker? {
        // A Mac workspace's native browser that is not routed through the
        // Mac (an older Mac's fallback pane) keeps no switch.
        guard browserServerRoute != nil else { return nil }
        let panels = browserStreamStore.panels(in: workspace.rpcWorkspaceID.rawValue)
        let target = panels.first { $0.panelID == browser.linkedStreamPanelID } ?? panels.first
        return MobileBrowserModePicker(
            current: .onDevice,
            unavailable: target == nil ? [.streamed: streamedUnavailableReason] : [:],
            select: { mode in
                guard mode == .streamed, let panelID = target?.panelID else { return }
                browserStore.forgetOnDevice(panelID: panelID)
                browserStore.closeBrowser(for: workspace.id.rawValue)
                selectBrowserStreamFromToolbar(panelID)
            }
        )
    }

    /// Why "On iPhone" cannot be chosen in this Mac workspace, or nil.
    private var macOnDeviceUnavailableReason: String? {
        switch store.macBrowserTunnelAvailability(macDeviceID: browserTunnelMacID) {
        case .available:
            nil
        case .needsMacUpdate:
            L10n.string("mobile.browser.mode.onDevice.unavailable.updateMac", defaultValue: "Update cmux on this Mac")
        case .routeWithoutLanes, .notConnected:
            L10n.string(
                "mobile.browser.mode.onDevice.unavailable.connection",
                defaultValue: "Not available on this connection"
            )
        }
    }

    /// The switch on a streamed tab (cmux-tui or Mac browser): opens its
    /// page on the phone.
    func streamedModePicker(_ stream: BrowserStreamSurfaceState) -> MobileBrowserModePicker? {
        let unavailable: [MobileBrowserMode: String]
        if sshHostID != nil {
            unavailable = [:]
        } else {
            unavailable = macOnDeviceUnavailableReason.map { [.onDevice: $0] } ?? [:]
        }
        return MobileBrowserModePicker(current: .streamed, unavailable: unavailable) { mode in
            guard mode == .onDevice, browserServerRoute != nil else { return }
            openStreamPanelOnDevice(stream.id, url: stream.url)
        }
    }

    /// Opens a streamed tab "On iPhone" when that was its last mode.
    /// Returns whether it did.
    func openStreamPanelOnDeviceIfPreferred(_ panelID: String) -> Bool {
        guard browserServerRoute != nil, browserStore.prefersOnDevice(panelID: panelID) else { return false }
        let url = browserStreamStore.panels(in: workspace.rpcWorkspaceID.rawValue)
            .first { $0.panelID == panelID }?.url
        openStreamPanelOnDevice(panelID, url: url)
        return true
    }

    /// Shows streamed tab `panelID` in the native browser, linked to the tab
    /// so switching back returns to it. The tab's phone-side page, once it
    /// has one, wins over the Mac tab's `url`.
    private func openStreamPanelOnDevice(_ panelID: String, url: String?) {
        dismissTerminalKeyboardForChrome()
        stopActiveBrowserStream()
        showLocalBrowser {
            browserStore.openOnDevice(for: $0, panelID: panelID, url: url.flatMap(URL.init(string:)))
        }
    }
}
#endif

#if os(iOS)

/// The SFTP browser opened from an SSH terminal's Files chip.
struct SSHFilesContext: Identifiable {
    let id = UUID()
    let hostID: UUID
    /// The terminal whose current directory the browser opens at.
    let surfaceID: String
}

extension WorkspaceDetailView {
    /// Whether `terminalID` is an SSH terminal, whose Files chip browses the
    /// server instead of listing files a Mac found on screen.
    func isSSHTerminal(_ terminalID: String) -> Bool {
        store.sshComputers.hostID(forIdentifier: terminalID) != nil
    }

    /// The terminal Browse Files in the title menu opens at: the shown SSH
    /// terminal, `nil` for Mac workspaces or while a browser covers it.
    var sshFilesTerminalID: String? {
        guard activeBrowser == nil, activeBrowserStream == nil, activeSimulatorStream == nil,
              let terminalID = selectedTerminal?.id.rawValue,
              isSSHTerminal(terminalID) else { return nil }
        return terminalID
    }

    /// Browse Files in the title menu: the Files chip's action for the shown
    /// terminal (HIG Toolbars: a document menu next to the title holds
    /// commands for the whole document).
    func browseFilesFromMenu() {
        guard let terminalID = sshFilesTerminalID else { return }
        presentSSHFiles(terminalID: terminalID)
    }

    /// Opens the file browser for an SSH terminal (Files chip, title menu).
    func presentSSHFiles(terminalID: String) {
        guard let hostID = store.sshComputers.hostID(forIdentifier: terminalID) else { return }
        dismissTerminalKeyboardForChrome()
        sshFilesContext = SSHFilesContext(hostID: hostID, surfaceID: terminalID)
    }

    func sshFilesSheet(_ context: SSHFilesContext) -> some View {
        let computers = store.sshComputers
        let surfaceID = context.surfaceID
        return SSHFileBrowserSheet(
            hostID: context.hostID,
            computers: computers,
            startDirectory: { await computers.currentDirectory(surfaceID: surfaceID) },
            insertPath: sshInsertPathAction(surfaceID: surfaceID)
        )
    }

    /// Types into the SSH terminal the browser was opened from, through the
    /// store's ordinary raw-input funnel, so it lands exactly like a keystroke.
    private func sshInsertPathAction(surfaceID: String) -> (String) -> Void {
        { [store] text in
            store.sendTerminalRawInput(Data(text.utf8), surfaceID: surfaceID)
        }
    }
}
#endif
