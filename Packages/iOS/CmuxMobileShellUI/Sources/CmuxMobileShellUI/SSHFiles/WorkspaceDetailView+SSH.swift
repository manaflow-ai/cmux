import CmuxMobileBrowser
import CmuxMobileShell
import CmuxMobileSupport
import SwiftUI

extension WorkspaceDetailView {
    /// The SSH computer behind this workspace, or `nil` for Mac workspaces.
    var sshHostID: UUID? {
        let computers = store.sshComputers
        return workspace.macDeviceID.flatMap(computers.hostID(forIdentifier:))
            ?? computers.hostID(forIdentifier: workspace.id.rawValue)
    }
}

#if os(iOS)

/// Sheets an SSH workspace offers from its title menu (PRD D7).
enum WorkspaceSSHSheet: String, Identifiable {
    case files
    case portForward

    var id: String { rawValue }
}

/// The SSH-only section of the workspace title menu.
struct WorkspaceSSHMenuSection: View {
    let openFiles: () -> Void
    let openPort: () -> Void

    var body: some View {
        Section {
            Button(action: openFiles) {
                Label(L10n.string("mobile.ssh.menu.files", defaultValue: "Files"), systemImage: "folder")
            }
            .accessibilityIdentifier("ssh.files")
            Button(action: openPort) {
                Label(
                    L10n.string("mobile.ssh.menu.openPort", defaultValue: "Open Port in Browser…"),
                    systemImage: "network"
                )
            }
            .accessibilityIdentifier("ssh.forward.open")
        }
    }
}

extension WorkspaceDetailView {
    @ViewBuilder
    var sshTitleMenuSection: some View {
        if sshHostID != nil {
            WorkspaceSSHMenuSection(
                openFiles: {
                    dismissTerminalKeyboardForChrome()
                    sshSheet = .files
                },
                openPort: {
                    dismissTerminalKeyboardForChrome()
                    sshSheet = .portForward
                }
            )
        }
    }

    @ViewBuilder
    func sshSheetContent(_ sheet: WorkspaceSSHSheet) -> some View {
        if let hostID = sshHostID {
            switch sheet {
            case .files:
                SSHFileBrowserSheet(
                    hostID: hostID,
                    computers: store.sshComputers,
                    insertPath: sshInsertPathAction
                )
            case .portForward:
                SSHPortForwardSheet(
                    hostID: hostID,
                    computers: store.sshComputers,
                    openInBrowser: openForwardedPortInBrowser
                )
            }
        }
    }

    /// Types into the workspace's selected SSH terminal through the store's
    /// ordinary raw-input funnel, so it lands exactly like a keystroke.
    private var sshInsertPathAction: ((String) -> Void)? {
        guard let terminalID = store.selectedTerminalID?.rawValue,
              store.sshComputers.hostID(forIdentifier: terminalID) == sshHostID else { return nil }
        return { [store] text in
            store.sendTerminalRawInput(Data(text.utf8), surfaceID: terminalID)
        }
    }

    /// Shows a forwarded port in this workspace's native WKWebView pane,
    /// the same pane New Browser opens (not the streamed Mac browser).
    private func openForwardedPortInBrowser(_ url: URL) {
        let workspaceID = workspace.id.rawValue
        // SSH workspaces have no Mac surfaces or streams to stop.
        store.selectedMacSurfaceID = nil
        browserStore.openBrowser(for: workspaceID).load(url)
        store.recordLastOpenedLocalBrowserTab(in: workspace.id)
    }
}
#endif
