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
                await MainActor.run { self?.publishRemoteTmuxBrowserProxyEndpointIfStillMirroring(endpoint, for: host) }
            } catch {
                await MainActor.run { self?.publishRemoteTmuxBrowserProxyEndpointIfStillMirroring(nil, for: host) }
            }
        }
    }

    /// A dropped-and-recovered ssh-tmux control connection reconnects with a
    /// fresh SSH session; the previously acquired `-D` dynamic forward and
    /// its SOCKS listener belonged to the old one and are now dead, but
    /// nothing in ``RemoteTmuxTransportRegistry``/``RemoteTmuxBrowserProxyRegistry``
    /// treats a reconnect (as opposed to the host being removed outright) as
    /// invalidating them — so without this, every browser tab on this host
    /// would keep being handed the same stale, now-unreachable endpoint.
    /// ``RemoteTmuxBrowserProxyRegistry/invalidateAndRebuild(connectionHash:)``
    /// preserves the host's existing retainers (unlike `releaseHost`, which
    /// would drop every OTHER mirror workspace's retention on this same
    /// host), and no-ops when nothing on this host has ever opened a
    /// browser, so calling this from every mirror workspace sharing the host
    /// that just reconnected is safe — merely redundant.
    func remoteTmuxBrowserProxyDidReconnect() {
        guard isRemoteTmuxMirror, let host = remoteTmuxBrowserProxyHost else { return }
        AppDelegate.shared?.remoteTmuxController.browserProxyRegistry.invalidateAndRebuild(connectionHash: host.connectionHash)
    }

    /// The registry's per-host ``RemoteTmuxBrowserProxyRegistry/acquire(host:workspaceID:)``
    /// is single-flighted across every
    /// mirror workspace on that host, so this workspace detaching (or
    /// re-mirroring onto a different host) while another mirror keeps the
    /// same acquisition alive must not let this now-stale continuation
    /// resurrect a proxy endpoint here — that would re-apply proxy
    /// configuration onto whatever (possibly shared, local) website data
    /// store this workspace's browser panels have since moved to.
    private func publishRemoteTmuxBrowserProxyEndpointIfStillMirroring(_ endpoint: BrowserProxyEndpoint?, for host: RemoteTmuxHost) {
        guard isRemoteTmuxMirror, remoteTmuxBrowserProxyHost == host else { return }
        applyRemoteProxyEndpointUpdate(endpoint)
    }
}
