public import Observation

/// Client-size + attach-redraw-kick (SIGWINCH) sub-model for one `tmux -CC` control
/// connection.
///
/// Owns the debounced `refresh-client -C` send that reflows the remote session to
/// the rendered cmux grid, plus the one-shot attach redraw kick that forces a
/// SIGWINCH when an attach's size push would otherwise be a no-op. Drives its owning
/// connection through ``RemoteTmuxClientSizeHost`` (plain `Int` sizes + a `Bool`
/// window-at-target check + command strings), so it never references the app-only
/// window/pane topology types.
@MainActor
@Observable
public final class RemoteTmuxClientSizeController {
    @ObservationIgnored
    private weak var host: (any RemoteTmuxClientSizeHost)?

    /// Last client size applied via ``setClientSize(columns:rows:)``, re-applied
    /// after a reconnect so the resumed session keeps the mirror's grid instead of
    /// reverting to ssh's default 80×24.
    public private(set) var lastClientSize: (columns: Int, rows: Int)?

    /// Trailing-edge debounce for `refresh-client -C`. SwiftUI layout settle makes the
    /// rendered grid oscillate (e.g. cols 154→155→156→161→…, ~15 distinct grids in
    /// ~1.3s), and each previously sent its own `refresh-client -C` → ~15 SIGWINCH /
    /// redraw storms on the remote per attach. We now coalesce them: ``setClientSize``
    /// stores the size immediately but defers the send to one shot after the size
    /// stops changing. The fired timer is also the clean "size settled" edge that
    /// consumes the one-shot attach redraw kick below.
    @ObservationIgnored
    private var clientSizeDebounceTask: Task<Void, Never>?
    private static let clientSizeDebounceMs = 180

    /// Armed on every transition to `.connected` (first connect AND reconnect) and
    /// consumed by the first size apply that follows; see
    /// ``scheduleAttachRedrawKickIfNeeded()`` for why attach needs a redraw kick.
    @ObservationIgnored
    private var pendingAttachRedrawKick = false
    @ObservationIgnored
    private var attachRedrawKickTask: Task<Void, Never>?
    /// Gap between the kick's shrink push and its restore push. Must exceed tmux's
    /// pane-resize coalescing (~250 ms), otherwise the two pushes collapse into a
    /// net-zero size change and no SIGWINCH is ever delivered.
    private static let attachRedrawKickGapMs = 350

    public init() {}

    /// Injects the owning connection as the command/state seam. Call once right after
    /// the connection constructs the controller.
    public func attach(host: any RemoteTmuxClientSizeHost) {
        self.host = host
    }

    /// Sizes the tmux control client to `columns`×`rows` cells (tmux
    /// `refresh-client -C`) so the remote windows/panes reflow to the rendered
    /// cmux grid. Without this a freshly attached session stays at ssh's default
    /// 80×24 and TUIs (claude, claude agents) render mangled. Always records the grid
    /// (re-applied by the connection's reconnect re-seed); sends the live
    /// `refresh-client` only while `.connected`. No-ops for a degenerate grid.
    ///
    /// This is the single sizing entrypoint every remote-tmux render path routes
    /// through (the single-pane display surface and the multi-pane window mirror),
    /// so client sizing stays one shared behavior rather than duplicated sends.
    public func setClientSize(columns: Int, rows: Int) {
        guard columns > 0, rows > 0 else { return }
        // Remember the grid so a reconnect can re-apply it (a fresh ssh client
        // otherwise reverts to 80×24 and mangles TUIs). Only send now when actually
        // connected — while reconnecting/ended there is no live stdin (the send would
        // silently drop); the reconnect re-seed re-applies the stored size.
        lastClientSize = (columns, rows)
        guard let host, host.isClientSizeConnectionConnected else { return }
        // Coalesce the layout-settle oscillation into a single send: (re)arm a short
        // trailing timer; only the last size in a burst actually goes out. The fired
        // timer is also the "settled" edge that consumes the attach redraw kick.
        clientSizeDebounceTask?.cancel()
        clientSizeDebounceTask = Task { @MainActor [weak self] in
            do {
                try await ContinuousClock().sleep(for: .milliseconds(Self.clientSizeDebounceMs))
            } catch {
                return
            }
            guard let self, let host = self.host, host.isClientSizeConnectionConnected,
                  let size = self.lastClientSize else { return }
            host.sendClientSizeCommand("refresh-client -C \(size.columns)x\(size.rows)")
            // This send already applied the stored grid — the deferred first-connect
            // apply would only duplicate it (a deferred reconnect re-seed must stay).
            host.clientSizeApplyDidCoverPendingPostAttachAction()
            // Do NOT re-capture here. A re-capture would run capture-pane before the
            // remote app (claude) finishes its post-SIGWINCH redraw, snapshotting the
            // stale pre-resize frame and clobbering the correct redraw — the exact
            // narrow/overlap/duplicate mangle. A manual resize is clean precisely
            // because it issues no capture: it lets refresh-client -C → SIGWINCH →
            // the app's own redraw stream back and paint. Attach does the same.
            self.scheduleAttachRedrawKickIfNeeded()
        }
    }

    /// Arms the one-shot attach redraw kick. Called on every transition to
    /// `.connected` (first connect AND reconnect); consumed by the first size apply
    /// that follows.
    public func armAttachRedrawKick() {
        pendingAttachRedrawKick = true
    }

    /// One-shot, attach-only: force a real SIGWINCH when the attach size push was a
    /// no-op, so a running TUI re-renders the current frame at the current width.
    ///
    /// Why this exists: tmux's grid stores an app's output as it was RENDERED — rows
    /// drawn at an earlier window width, or an inline TUI's streaming churn, stay in
    /// the visible frame verbatim. tmux has no "redraw" command for a control (-CC)
    /// client (`%output` is an append-only pty copy; tmux never re-streams grid
    /// cells), and `capture-pane` re-reads the same stale cells, so the ONLY way to
    /// get a clean current-width frame is the app's own repaint — which apps do on
    /// SIGWINCH. A real-terminal attach virtually always delivers that SIGWINCH
    /// because its size differs from the detached window's size. The mirror's attach
    /// usually does NOT: the window still has the size cmux itself left behind, so
    /// `refresh-client -C` matches it exactly, no pane resize happens, and the stale
    /// frame stays until the user manually resizes. This kick closes that one gap by
    /// sending the same signal a real attach sends: a genuine size change (rows-1),
    /// then the true size after tmux's resize-coalescing window has passed.
    ///
    /// Ordering is safe vs the seed: the kick is scheduled after the capture-pane
    /// commands, and the tmux server processes commands FIFO, so the app's redraw
    /// `%output` always lands after (on top of) the seed paint. Skipped entirely when
    /// the attach push itself changed the window size (that already SIGWINCHes), and
    /// invisible for plain-shell panes (nothing re-renders, nothing is streamed).
    public func scheduleAttachRedrawKickIfNeeded() {
        guard pendingAttachRedrawKick else { return }
        // Not ready yet (no grid computed / topology not drained): keep the one-shot
        // armed for the next size apply instead of consuming it uselessly.
        guard let host, host.isClientSizeConnectionConnected,
              let size = lastClientSize, host.hasMirroredWindowTopology else { return }
        pendingAttachRedrawKick = false
        guard size.rows > 2 else { return }
        // Only kick when some mirrored window ALREADY has the target size — i.e. the
        // size apply above cannot produce a SIGWINCH for it. (window-size latest makes
        // every window track the client, so one client-level kick redraws them all.)
        let windowAlreadyAtTarget = host.mirroredWindowMatchesClientSize(columns: size.columns, rows: size.rows)
        guard windowAlreadyAtTarget else {
            host.logClientSizeEvent("remote.size.kick skip=windowSizeDiffers target=\(size.columns)x\(size.rows)")
            return
        }
        host.logClientSizeEvent("remote.size.kick shrink to \(size.columns)x\(size.rows - 1)")
        attachRedrawKickTask?.cancel()
        attachRedrawKickTask = Task { @MainActor [weak self] in
            guard let self, let host = self.host, host.isClientSizeConnectionConnected else { return }
            // Bail if the user resized since the kick was scheduled: that resize is a
            // real size change, so it already delivered the SIGWINCH this kick exists
            // to force — and a shrink at the captured (now stale) size would flash
            // wrong dimensions at the remote apps.
            guard let current = self.lastClientSize, current == size else { return }
            host.sendClientSizeCommand("refresh-client -C \(size.columns)x\(size.rows - 1)")
            do {
                try await ContinuousClock().sleep(for: .milliseconds(Self.attachRedrawKickGapMs))
            } catch {
                return
            }
            guard host.isClientSizeConnectionConnected else { return }
            // Restore the CURRENT size (the user may have resized during the gap).
            let restore = self.lastClientSize ?? size
            host.logClientSizeEvent("remote.size.kick restore to \(restore.columns)x\(restore.rows)")
            host.sendClientSizeCommand("refresh-client -C \(restore.columns)x\(restore.rows)")
        }
    }

    /// Cancels the debounced size send and the redraw kick, and disarms the one-shot
    /// kick. Shared by deliberate teardown (``RemoteTmuxControlConnection/stop()``)
    /// and a genuine remote end (`%exit`). Leaves `lastClientSize` intact so a later
    /// reconnect can re-apply the grid.
    public func reset() {
        clientSizeDebounceTask?.cancel()
        clientSizeDebounceTask = nil
        attachRedrawKickTask?.cancel()
        attachRedrawKickTask = nil
        pendingAttachRedrawKick = false
    }
}
