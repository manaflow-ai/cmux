import CmuxCore
import CmuxRemoteWorkspace
import Foundation

/// ssh-tmux's browser-preview proxy: a mirror workspace's browser tab (see
/// `newBrowserSurface(inPane:)`) routes through a local SOCKS proxy over the
/// ssh-tmux host's SSH connection (`RemoteTmuxBrowserProxyRegistry`), so it
/// can preview a port on the remote host the same way a plain `cmux ssh`
/// workspace's browser already can. This file owns only the forward's
/// lifecycle — UI placement lives entirely in `Workspace.newBrowserSurface`.
extension Workspace {
    /// The ssh-tmux host backing this mirror workspace, if any.
    var remoteTmuxBrowserProxyHost: RemoteTmuxHost? {
        remoteTmuxSessionMirror?.host
    }

    /// Idempotent: ensures a browser-proxy forward exists for this mirror
    /// workspace's host and publishes `remoteProxyEndpoint` once it's ready.
    /// Safe to call from any action path; never from SwiftUI `body`. No-ops
    /// for a non-mirror workspace. Acquired lazily here (not at mirror
    /// creation) since most mirrored sessions never open a browser.
    func ensureRemoteTmuxBrowserProxyForward() {
        guard isRemoteTmuxMirror, let host = remoteTmuxBrowserProxyHost else { return }
        guard let controller = AppDelegate.shared?.remoteTmuxController else { return }
        let task = controller.browserProxyRegistry.acquire(host: host, workspaceID: id)
        Task { [weak self] in
            do {
                let endpoint = try await task.value
                await MainActor.run { self?.applyRemoteProxyEndpointUpdate(endpoint) }
            } catch {
                await MainActor.run { self?.applyRemoteProxyEndpointUpdate(nil) }
            }
        }
    }
}
