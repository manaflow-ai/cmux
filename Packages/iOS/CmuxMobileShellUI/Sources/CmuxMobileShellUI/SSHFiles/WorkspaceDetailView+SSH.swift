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
}

#if os(iOS)
/// The Streamed / On iPhone switch (SSH workspaces only). A Mac workspace
/// shows no switch: "On iPhone" would need a tunnel through the Mac, which
/// does not exist, and a menu whose only other item can never be chosen
/// adds nothing.
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
        guard sshHostID != nil else { return nil }
        let panels = browserStreamStore.panels(in: workspace.rpcWorkspaceID.rawValue)
        let target = panels.first { $0.panelID == browser.linkedStreamPanelID } ?? panels.first
        return MobileBrowserModePicker(
            current: .onDevice,
            unavailable: target == nil ? [.streamed: streamedUnavailableReason] : [:],
            select: { mode in
                guard mode == .streamed, let panelID = target?.panelID else { return }
                browserStore.rememberOnDevice(false, panelID: panelID)
                browserStore.closeBrowser(for: workspace.id.rawValue)
                selectBrowserStreamFromToolbar(panelID)
            }
        )
    }

    /// The switch on a streamed cmux-tui tab: opens its page on the phone.
    func streamedModePicker(_ stream: BrowserStreamSurfaceState) -> MobileBrowserModePicker? {
        guard sshHostID != nil else { return nil }
        return MobileBrowserModePicker(current: .streamed) { mode in
            guard mode == .onDevice else { return }
            browserStore.rememberOnDevice(true, panelID: stream.id)
            openStreamPanelOnDevice(stream.id, url: stream.url)
        }
    }

    /// Opens a streamed tab "On iPhone" when that was its last mode.
    /// Returns whether it did.
    func openStreamPanelOnDeviceIfPreferred(_ panelID: String) -> Bool {
        guard sshHostID != nil, browserStore.prefersOnDevice(panelID: panelID) else { return false }
        let url = browserStreamStore.panels(in: workspace.rpcWorkspaceID.rawValue)
            .first { $0.panelID == panelID }?.url
        openStreamPanelOnDevice(panelID, url: url)
        return true
    }

    /// Shows the page of streamed tab `panelID` in the native browser,
    /// linked to the tab so switching back returns to it.
    private func openStreamPanelOnDevice(_ panelID: String, url: String?) {
        dismissTerminalKeyboardForChrome()
        stopActiveBrowserStream()
        openLocalBrowserFallback()
        let browser = browserStore.openBrowser(for: workspace.id.rawValue)
        browser.linkedStreamPanelID = panelID
        if let url, let parsed = URL(string: url), ["http", "https"].contains(parsed.scheme?.lowercased() ?? "") {
            browser.load(parsed)
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

    /// Opens the file browser for an SSH terminal's Files chip.
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
