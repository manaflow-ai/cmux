#if os(iOS)
import CmuxMobileSSH
import CmuxMobileShell
import CmuxMobileSupport
import SwiftUI

/// Where the file browser's navigation stack can go.
enum SSHFilesRoute: Hashable {
    case directory(String)
    case file(path: String, name: String)
}

/// SFTP file browser for an SSH computer (PRD D7), presented from the SSH
/// workspace's title menu. Starts in the remote home folder; folders push,
/// files open a Quick Look preview with Share and Save to Files.
struct SSHFileBrowserSheet: View {
    @State private var model: SSHFileBrowserModel
    @State private var path: [SSHFilesRoute] = []
    /// Types a shell-quoted remote path into the workspace's SSH terminal,
    /// or `nil` when no SSH terminal is selected.
    let insertPath: ((String) -> Void)?
    @Environment(\.dismiss) private var dismiss

    init(hostID: UUID, computers: MobileSSHComputers, insertPath: ((String) -> Void)?) {
        _model = State(initialValue: SSHFileBrowserModel(hostID: hostID, computers: computers))
        self.insertPath = insertPath
    }

    var body: some View {
        NavigationStack(path: $path) {
            root
                .navigationDestination(for: SSHFilesRoute.self) { route in
                    switch route {
                    case .directory(let directory):
                        SSHDirectoryView(model: model, path: directory, actions: actions)
                    case .file(let remotePath, let name):
                        SSHFilePreviewView(model: model, remotePath: remotePath, name: name, actions: actions)
                    }
                }
        }
        .task { await model.start() }
        .onDisappear { model.close() }
        .accessibilityIdentifier("ssh.files.sheet")
    }

    @ViewBuilder
    private var root: some View {
        if let home = model.homePath {
            SSHDirectoryView(model: model, path: home, actions: actions)
        } else if let error = model.homeError {
            ContentUnavailableView {
                Label(
                    L10n.string("mobile.ssh.files.unavailable", defaultValue: "Can't Open Files"),
                    systemImage: "exclamationmark.triangle"
                )
            } description: {
                Text(error)
            } actions: {
                Button(L10n.string("mobile.ssh.files.retry", defaultValue: "Try Again")) {
                    Task { await model.start() }
                }
            }
            .toolbar { doneToolbarItem }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .toolbar { doneToolbarItem }
        }
    }

    private var doneToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) {
            Button(L10n.string("mobile.ssh.files.done", defaultValue: "Done")) { dismiss() }
        }
    }

    private var actions: SSHFileBrowserActions {
        SSHFileBrowserActions(
            open: { path.append($0) },
            done: { dismiss() },
            insertPath: insertPath.map { insert in
                { remotePath in
                    insert(MobileSSHShellQuoting.quote(remotePath))
                    dismiss()
                }
            }
        )
    }
}

/// Navigation and terminal hooks shared by every screen in the browser.
struct SSHFileBrowserActions {
    let open: (SSHFilesRoute) -> Void
    let done: () -> Void
    let insertPath: ((String) -> Void)?
}
#endif
