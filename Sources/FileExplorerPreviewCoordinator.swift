import AppKit
import Bonsplit

/// Both sidebar entrypoints capture the displayed provider before suspending.
@MainActor
struct FileExplorerPreviewCoordinator {
    let store: FileExplorerStore

    func open(path: String, workspace: Workspace, pane: PaneID, isCurrent: @escaping @MainActor () -> Bool) {
        guard store.workspaceRootIdentity == workspace.id, let provider = store.provider,
              provider.isAvailable else { return }
        let context = store.resourceContextID
        if provider is LocalFileExplorerProvider {
            guard !workspace.usesRemoteDirectoryProvenance else { return }
            _ = workspace.openFileSurfaces(inPane: pane, filePaths: [path], focus: true,
                                          reuseExisting: true, duplicateWhenFocused: true)
            return
        }
        Task { [weak workspace, store] in
            guard let workspace else { return }
            do {
                guard isCurrent(), store.resourceContextID == context else { return }
                if let cloud = provider as? CloudVMFileExplorerProvider {
                    guard let target = cloud.target else { throw FileExplorerError.providerUnavailable }
                    try target.validate(vmID: cloud.vmID)
                    let lease = try await store.cloudPreviewCache.materialize(path: path, provider: cloud)
                    guard isCurrent(), store.resourceContextID == context else { return }
                    try target.validate(vmID: cloud.vmID)
                    // Markdown also uses the read-only file preview: its links must
                    // never resolve relative remote paths through the Mac browser.
                    if let panel = workspace.openFilePreviewSurfaces(inPane: pane, filePaths: [lease.url.path],
                        focus: true, reuseExisting: false).first {
                        panel.cloudPreviewLease = lease
                    }
                } else if let remote = provider as? any RemoteFileExplorerProvider {
                    let lease = try await store.cloudPreviewCache.materialize(path: path, provider: remote)
                    guard isCurrent(), store.resourceContextID == context else { return }
                    if let panel = workspace.openFilePreviewSurfaces(inPane: pane, filePaths: [lease.url.path],
                        focus: true, reuseExisting: false).first {
                        panel.cloudPreviewLease = lease
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                guard isCurrent(), store.resourceContextID == context else { return }
                present(error, window: AppDelegate.shared?.mainWindowContainingWorkspace(workspace.id))
            }
        }
    }

    private func present(_ error: Error, window: NSWindow?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "fileExplorer.preview.failedTitle", defaultValue: "Unable to open remote file")
        alert.informativeText = (error as? FileExplorerError)?.localizedDescription
            ?? String(localized: "fileExplorer.preview.genericFailure", defaultValue: "The remote file could not be downloaded. Reconnect and try again.")
        alert.addButton(withTitle: String(localized: "alert.invalidColor.ok", defaultValue: "OK"))
        _ = alert.runCmuxModal(presentingWindow: window)
    }
}
