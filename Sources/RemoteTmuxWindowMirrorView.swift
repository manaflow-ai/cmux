import SwiftUI

/// Renders a mirrored tmux window's multi-pane layout as nested splits inside a
/// single cmux tab. Each pane is a real ``TerminalPanel`` (rendered via
/// ``TerminalPanelView`` for native chrome) topped with a small control header
/// (split / close) that doubles as a clearly visible separator between panes.
@MainActor
struct RemoteTmuxWindowMirrorView: View {
    let mirror: RemoteTmuxWindowMirror
    let appearance: PanelAppearance
    let isVisibleInUI: Bool
    let portalPriority: Int
    /// Pane-header ✕ handler — owned by the workspace layer so the kill-pane can
    /// be gated on a close confirmation (the view stays dialog-free).
    let onClosePane: (Int) -> Void
    @State private var sizingRetryTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { geo in
            RemoteTmuxLayoutContainer(
                node: mirror.layout,
                mirror: mirror,
                appearance: appearance,
                isVisibleInUI: isVisibleInUI,
                portalPriority: portalPriority,
                onClosePane: onClosePane
            )
            .frame(width: geo.size.width, height: geo.size.height)
            // Size the remote tmux window to the rendered area so pane content
            // matches the on-screen grid. Local triggers (mount, outer resize,
            // tab shown) also refill the mirror's geometry-correction budget —
            // they cannot be tmux echoes, so they are safe reset points.
            .onAppear { mirror.noteLocalSizingTrigger(); scheduleClientSize() }
            .onChange(of: geo.size) { _, _ in mirror.noteLocalSizingTrigger(); scheduleClientSize() }
            // Tabs are kept mounted across selection (keepAllAlive), so onAppear
            // fires once per tab lifetime and never on re-select. Re-arm when the
            // tab becomes visible again: another writer may have moved the shared
            // client size while this tab was hidden, and the visible tab should
            // own the size it renders at.
            .onChange(of: isVisibleInUI) { _, visible in
                if visible { mirror.noteLocalSizingTrigger(); scheduleClientSize() }
            }
            // The size we report to tmux depends on the pane COUNT — each split adds
            // a separator column/row to the summed grid — so a split/close must
            // re-push it. But a split changes the layout without changing the outer
            // tab area, so onChange(geo.size) never fires for it. Re-arm on the
            // layout's STRUCTURE version rather than the layout value: every push
            // comes back as a geometry-only `%layout-change` (tmux reflowing the
            // window to the size we just sent), and a size recomputed from grids
            // that reflow just re-divided has no fixed point at some pixel widths —
            // re-pushing on that echo oscillates the client size ±1 column
            // indefinitely. (onAppear covers the 1→N mount into the mirror; this
            // covers N→N±1 splits/closes within an already-mounted mirror.)
            .onChange(of: mirror.layoutStructureVersion) { _, _ in scheduleClientSize() }
            // Budgeted correction for geometry-only layout changes (a co-client's
            // resize-pane, or another writer moving the shared client size). The
            // mirror bumps this at most twice between local/structural triggers,
            // so a foreign change heals in one bounded pass while an echo storm
            // burns out instead of oscillating (see sizingCorrectionVersion).
            .onChange(of: mirror.sizingCorrectionVersion) { _, _ in scheduleClientSize() }
            .onDisappear { sizingRetryTask?.cancel() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Match the terminal background so the area never shows through as black.
        .background(Color(nsColor: appearance.backgroundColor))
    }

    /// Pushes the client size to tmux, retrying briefly while a pane surface hasn't
    /// reported a live grid yet — so the initial `refresh-client -C` lands even when
    /// the view size never changes after attach. Each call restarts the retry, so a
    /// trigger arriving before the surfaces are live isn't lost. `updateClientSize`
    /// reads the summed rendered grids itself (no size argument needed), dedups, and
    /// reports readiness.
    ///
    /// After the first successful push, a short settle-confirm pass re-samples the
    /// grids a few more times: a push fired from a trigger (mount, outer resize,
    /// split/close) can read grids the layout pass hasn't re-divided yet, and the
    /// geometry-only `%layout-change` that follows is deliberately not a re-arm
    /// trigger (see `layoutStructureVersion`) — without a confirm pass a mid-settle
    /// read would stick until the next trigger. The pass is TIME-bounded and
    /// trigger-scoped, never echo-triggered, so it cannot reopen the resize
    /// feedback loop: at a width with no quantization fixed point it stops after
    /// the last round instead of alternating forever, and everywhere else the
    /// `lastClientSize` dedup makes the extra rounds free.
    private func scheduleClientSize() {
        sizingRetryTask?.cancel()
        sizingRetryTask = Task { @MainActor in
            // Phase 1: wait for every pane surface to report a live grid (local
            // layout timing, normally a frame or two; budget generously for a
            // loaded system). do/catch (not try?) so a cancelled sleep returns
            // immediately without a stale apply.
            var ready = mirror.updateClientSize()
            var waitRounds = 0
            while !ready {
                guard waitRounds < 20 else { return }
                waitRounds += 1
                do { try await ContinuousClock().sleep(for: .milliseconds(150)) } catch { return }
                ready = mirror.updateClientSize()
            }
            // Phase 2: the settle-confirm pass always gets its full budget, no
            // matter how late readiness arrived — truncating it re-opens the
            // stuck-mid-settle-size window it exists to close.
            for _ in 0..<4 {
                do { try await ContinuousClock().sleep(for: .milliseconds(250)) } catch { return }
                mirror.updateClientSize()
            }
        }
    }
}
