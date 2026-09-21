import CmuxCore
import CmuxRemoteWorkspace
import Foundation

/// ssh-tmux's browser-preview proxy: a mirror workspace's browser tab or split
/// routes through a local SOCKS proxy over the host's SSH connection
/// (`RemoteTmuxBrowserProxyRegistry`), previewing a port on the remote host the
/// way a plain `cmux ssh` workspace's browser already can. This extension owns
/// only the forward's lifecycle; UI placement lives in the callers.
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
                await MainActor.run { self?.publishRemoteTmuxBrowserProxyEndpointIfStillMirroring(endpoint, for: host) }
            } catch {
                await MainActor.run { self?.publishRemoteTmuxBrowserProxyEndpointIfStillMirroring(nil, for: host) }
            }
        }
    }

    /// A reconnected ssh-tmux control connection is a fresh SSH session, so the
    /// previously acquired `-D` forward and its SOCKS listener are dead — and
    /// nothing else treats a reconnect (as opposed to the host being removed
    /// outright) as invalidating them, so without this every browser tab on the
    /// host keeps being handed the same stale endpoint. Harmless to call from
    /// every mirror sharing the reconnected host: the rebuild preserves existing
    /// retainers, and no-ops when no browser has ever opened here.
    func remoteTmuxBrowserProxyDidReconnect() {
        guard isRemoteTmuxMirror, let host = remoteTmuxBrowserProxyHost else { return }
        AppDelegate.shared?.remoteTmuxController.browserProxyRegistry.invalidateAndRebuild(connectionHash: host.connectionHash)
    }

    /// `acquire` is single-flighted per host, so this workspace can detach (or
    /// re-mirror onto a different host) while another mirror keeps the same
    /// acquisition alive. The now-stale continuation must not resurrect an
    /// endpoint here — that would re-apply proxy configuration onto whatever
    /// (possibly shared, local) data store this workspace's panels moved to.
    private func publishRemoteTmuxBrowserProxyEndpointIfStillMirroring(_ endpoint: BrowserProxyEndpoint?, for host: RemoteTmuxHost) {
        guard isRemoteTmuxMirror, remoteTmuxBrowserProxyHost == host else { return }
        applyRemoteProxyEndpointUpdate(endpoint)
    }
}
