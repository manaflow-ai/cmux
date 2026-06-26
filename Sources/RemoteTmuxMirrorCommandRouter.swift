import Foundation

/// Routes mirror user-actions (new tab, rename, reorder, split, paste, close)
/// from cmux surfaces to the remote `tmux -CC` control connection, and answers
/// the mirror-membership lookups those routes depend on.
///
/// Owned by ``RemoteTmuxController`` and constructed with the controller's
/// shared ``RemoteTmuxSessionMirrorRegistry`` and
/// ``RemoteTmuxControlConnectionRegistry`` (both reference types), so the router
/// reads and re-keys exactly the same live mirror/connection state the
/// controller does. `@MainActor` to match the controller's isolation; it holds
/// no UI/AppDelegate state, only the two injected registries.
@MainActor
final class RemoteTmuxMirrorCommandRouter {
    /// Active session→workspace mirrors keyed `connectionHash\u{1}session`,
    /// shared with (and owned by) ``RemoteTmuxController``.
    private let mirrorRegistry: RemoteTmuxSessionMirrorRegistry

    /// Live `tmux -CC` control connections keyed `connectionHash\u{1}session`,
    /// shared with (and owned by) ``RemoteTmuxController``.
    private let connectionRegistry: RemoteTmuxControlConnectionRegistry

    init(
        mirrorRegistry: RemoteTmuxSessionMirrorRegistry,
        connectionRegistry: RemoteTmuxControlConnectionRegistry
    ) {
        self.mirrorRegistry = mirrorRegistry
        self.connectionRegistry = connectionRegistry
    }

    // MARK: - Create / destroy propagation (P5)

    /// A new tab was requested in a mirrored workspace → create a tmux window in
    /// that session. The new tab arrives via the `%window-add` notification (one
    /// source of truth), so the caller must NOT also create a local tab.
    ///
    /// Requires a live `.connected` stream — NOT just `!exited`: while
    /// reconnecting there is no stdin and `send` silently drops the command, so
    /// returning `true` would let socket callers report an accepted mutation
    /// that never reached tmux.
    ///
    /// - Returns: `true` if routed to the remote; `false` if there is no live
    ///   mirror/connection (callers must still NOT create a local tab in a
    ///   mirror workspace — they report failure instead).
    func handleMirrorNewTabRequested(workspaceId: UUID) -> Bool {
        guard let mirror = mirrorRegistry.allMirrors().first(where: { $0.mirroredWorkspaceId == workspaceId }),
              mirror.connection.connectionState == .connected else { return false }
        return mirror.connection.send("new-window")
    }

    /// A mirrored workspace was renamed → `rename-session` on the remote so the
    /// tmux session name tracks the cmux workspace title.
    func handleMirrorWorkspaceRenamed(workspaceId: UUID, title: String?) {
        guard let name = RemoteTmuxHost.controlModeCommandName(title),
              let mirror = mirrorRegistry.allMirrors().first(where: { $0.mirroredWorkspaceId == workspaceId })
        else { return }
        let oldName = mirror.sessionName
        guard name != oldName, mirror.connection.connectionState == .connected else { return }
        // Target by the stable session id when known, so the rename can't race a
        // prior rename's name.
        guard let target = mirror.connection.sessionId.map({ "$\($0)" })
            ?? RemoteTmuxHost.controlModeLineSafeName(oldName).map(RemoteTmuxHost.shellSingleQuoted)
        else { return }
        _ = mirror.connection.send("rename-session -t \(target) \(RemoteTmuxHost.shellSingleQuoted(name))")
        // Do not re-key local state here. tmux can reject a rename (for example
        // duplicate session name); `%session-changed` is the confirmation point.
    }

    /// Tmux confirmed that a mirrored session's name changed. This is the single
    /// place that re-keys controller dictionaries keyed by host+session name.
    func handleMirrorSessionNameChanged(
        mirror: RemoteTmuxSessionMirror,
        oldName: String,
        newName: String
    ) {
        guard let safeName = RemoteTmuxHost.controlModeLineSafeName(newName),
              oldName != safeName else {
            return
        }
        let host = mirror.host
        let oldKey = host.connectionKey(sessionName: oldName)
        let newKey = host.connectionKey(sessionName: safeName)
        if let existing = mirrorRegistry.mirror(forKey: newKey), existing !== mirror { return }
        if let existing = connectionRegistry.connection(forKey: newKey), existing !== mirror.connection { return }

        mirror.setSessionName(safeName)
        mirror.connection.setSessionName(safeName)

        if oldKey != newKey {
            mirrorRegistry.rekey(from: oldKey, to: newKey, matching: mirror)
            connectionRegistry.rekey(from: oldKey, to: newKey, matching: mirror.connection)
        }
    }

    /// Mirror tabs were drag-reordered → reorder the tmux windows to match.
    ///
    /// Uses `swap-window` (selection-sort over the current order), NOT
    /// `move-window`: `move-window` unlinks+relinks a window, which in control
    /// mode emits `%window-close`/`%window-add` and transiently empties the
    /// mirror workspace — causing cmux to auto-seed a stray local terminal tab.
    /// `swap-window` only swaps two windows' indices (no unlink), so there is no
    /// churn. `-d` keeps the active window unchanged.
    func handleMirrorWindowsReordered(workspaceId: UUID, orderedPanelIds: [UUID]) {
        guard let mirror = mirrorRegistry.allMirrors().first(where: { $0.mirroredWorkspaceId == workspaceId }),
              mirror.connection.connectionState == .connected else { return }
        let desired = orderedPanelIds.compactMap { mirror.windowId(forPanel: $0) }
        guard desired.count >= 2 else { return }
        // Current tmux window order (as last reported by list-windows), restricted
        // to the windows we're reordering. Bail if the sets diverge, so we never
        // issue a swap against a window the mirror doesn't currently track.
        let desiredSet = Set(desired)
        var current = mirror.connection.windowOrder.filter { desiredSet.contains($0) }
        guard current.count == desired.count, Set(current) == desiredSet else { return }
        var swapped = false
        for index in desired.indices where current[index] != desired[index] {
            guard let swapFrom = current.firstIndex(of: desired[index]) else { continue }
            guard mirror.connection.send("swap-window -d -s @\(current[index]) -t @\(current[swapFrom])") else {
                return
            }
            current.swapAt(index, swapFrom)
            swapped = true
        }
        // `swap-window` changes window indices but emits no notification cmux
        // re-reads the order from, so update the tracked order locally. The swaps
        // achieve exactly `desired`, so this matches tmux and a rapid follow-up
        // drag computes against the just-applied order. (Deliberately NOT a
        // `requestWindows()` re-fetch: its async snapshot could land after a later
        // reorder and roll the order back, reintroducing the race; out-of-band
        // changes reconcile on the topology events that re-fetch anyway.)
        if swapped { mirror.connection.applyWindowReorder(desired) }
    }

    /// A split was requested from a mirrored multi-pane surface → propagate to
    /// tmux `split-window`. The new pane arrives via the resulting
    /// `%layout-change`. Returns `true` if `surfaceId` is a mirror pane (the
    /// caller suppresses the local split).
    func handleMirrorSplitRequested(surfaceId: UUID, vertical: Bool) -> Bool {
        for sessionMirror in mirrorRegistry.allMirrors() {
            if let match = sessionMirror.windowMirror(forSurfaceId: surfaceId) {
                return match.mirror.requestSplit(fromPane: match.tmuxPaneId, vertical: vertical)
            }
        }
        return false
    }

    /// Whether `surfaceId` is a pane of a mirrored multi-pane tmux window (used
    /// to keep the context-menu Split items enabled for mirror panes).
    func isMirrorPaneSurface(_ surfaceId: UUID) -> Bool {
        for sessionMirror in mirrorRegistry.allMirrors() {
            if sessionMirror.windowMirror(forSurfaceId: surfaceId) != nil { return true }
        }
        return false
    }

    /// If `surfaceId` is a remote-tmux mirror pane, delivers `text` to that pane as
    /// a tmux paste (`paste-buffer -p`, bracketed iff the real pane has
    /// bracketed-paste mode on) and returns `true`. Lets a pasted/dropped image
    /// path be recognized by the remote app (e.g. claude → `[Image #N]`) instead of
    /// arriving as plain `send-keys`. Only single-line `text` is routed (covers
    /// file/image paths); callers fall back to their normal insertion for empty or
    /// multi-line text, which can't be carried safely on a one-line control command.
    func pasteIntoMirror(surfaceId: UUID, text: String) -> Bool {
        guard !text.isEmpty, !text.contains(where: { $0 == "\n" || $0 == "\r" }) else { return false }
        guard let target = pasteTarget(forSurfaceId: surfaceId) else { return false }
        return target.connection.pastePane(paneId: target.paneId, text: text)
    }

    /// The live control connection + tmux pane id behind a remote-tmux
    /// session-mirror surface, or `nil`.
    private func pasteTarget(forSurfaceId surfaceId: UUID)
        -> (connection: RemoteTmuxControlConnection, paneId: Int)?
    {
        for sessionMirror in mirrorRegistry.allMirrors() where sessionMirror.connection.connectionState == .connected {
            if let paneId = sessionMirror.paneId(forSurfaceId: surfaceId) {
                return (sessionMirror.connection, paneId)
            }
        }
        return nil
    }

    /// The SSH upload target for a remote-tmux session-mirror surface, or `nil` if
    /// `surfaceId` isn't one. Lets the image-paste path upload a pasted screenshot
    /// to the remote tmux host (and insert the remote path) instead of an
    /// unreadable macOS-local one.
    func remoteUploadTarget(forSurfaceId surfaceId: UUID) -> TerminalRemoteUploadTarget? {
        for sessionMirror in mirrorRegistry.allMirrors()
        where !sessionMirror.connection.exited && sessionMirror.ownsSurface(surfaceId) {
            return .detectedSSH(sessionMirror.host.detectedSSHSession())
        }
        return nil
    }

    /// A split was requested on a mirror window-tab (the split button / any
    /// bonsplit-level split) → propagate to tmux `split-window`. Covers both
    /// single-pane mirror windows and multi-pane ones. Returns `true` if handled.
    func handleMirrorTabSplitRequested(workspaceId: UUID, panelId: UUID, vertical: Bool) -> Bool {
        guard let mirror = mirrorRegistry.allMirrors().first(where: { $0.mirroredWorkspaceId == workspaceId })
        else { return false }
        return mirror.requestSplit(windowPanelId: panelId, vertical: vertical)
    }

    /// A mirrored window's tab was renamed → `rename-window` on the remote.
    func handleMirrorWindowRenamed(workspaceId: UUID, panelId: UUID, title: String?) {
        guard let name = RemoteTmuxHost.controlModeCommandName(title),
              let mirror = mirrorRegistry.allMirrors().first(where: { $0.mirroredWorkspaceId == workspaceId }),
              mirror.connection.connectionState == .connected,
              let windowId = mirror.windowId(forPanel: panelId) else { return }
        _ = mirror.connection.send("rename-window -t @\(windowId) \(RemoteTmuxHost.shellSingleQuoted(name))")
    }

    /// The live session mirror + tmux window id behind a mirrored window-tab, or
    /// `nil` when `panelId` isn't a mirrored window-tab of `workspaceId` with a
    /// live connection. Shared by the kill routing and the close-confirmation
    /// check so the two can never disagree about which tabs route remotely.
    ///
    /// Exposed `internal` (not `private`) because ``RemoteTmuxController``'s
    /// close-time activity queries (`cachedMirrorTabActivity`/
    /// `queryMirrorTabActivity`) resolve the same target through this router.
    func mirrorWindowTarget(workspaceId: UUID, panelId: UUID)
        -> (mirror: RemoteTmuxSessionMirror, windowId: Int)?
    {
        guard let mirror = mirrorRegistry.allMirrors().first(where: { $0.mirroredWorkspaceId == workspaceId }),
              let windowId = mirror.windowId(forPanel: panelId) else { return nil }
        return (mirror, windowId)
    }

    /// Whether the panel is currently a tmux window tab in a mirrored workspace.
    /// This lets non-interactive socket close paths route or reject before they
    /// mark the tab as a forced local close.
    func isMirrorWindowTab(workspaceId: UUID, panelId: UUID) -> Bool {
        mirrorWindowTarget(workspaceId: workspaceId, panelId: panelId) != nil
    }

    /// A tab close was requested in a mirrored workspace → kill that tmux window
    /// on the remote. The local tab is removed when tmux reports `%window-close`,
    /// so the caller should VETO the immediate local close.
    ///
    /// - Returns: `true` if routed to the remote (caller vetoes the local close);
    ///   `false` if there is no live mirror/connection or the panel isn't a
    ///   mirrored window (caller proceeds with the normal local close).
    func handleMirrorTabCloseRequested(workspaceId: UUID, panelId: UUID) -> Bool {
        guard let target = mirrorWindowTarget(workspaceId: workspaceId, panelId: panelId),
              target.mirror.connection.connectionState == .connected else { return false }
        return target.mirror.connection.send("kill-window -t @\(target.windowId)")
    }
}
