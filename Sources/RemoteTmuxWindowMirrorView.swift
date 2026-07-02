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
            // matches the on-screen grid.
            .onAppear { scheduleClientSize() }
            .onChange(of: geo.size) { _, _ in scheduleClientSize() }
            // The size we report to tmux now depends on the pane COUNT — each split
            // adds a separator column/row to the summed grid — so a split/close must
            // re-push it. But a split changes `mirror.layout` without changing the
            // outer tab area, so onChange(geo.size) never fires for it. Re-arm on the
            // layout itself; otherwise the new pane keeps the pre-split size and the
            // "%" strands again. (onAppear covers the 1→N mount into the mirror; this
            // covers N→N±1 splits/closes within an already-mounted mirror.)
            .onChange(of: mirror.layout) { _, _ in scheduleClientSize() }
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
    /// reports readiness, so the retry stops as soon as every surface goes live.
    private func scheduleClientSize() {
        sizingRetryTask?.cancel()
        if mirror.updateClientSize() { return }
        sizingRetryTask = Task { @MainActor in
            // Retry until the pane surfaces report their grids (local layout timing,
            // normally a frame or two; budget generously for a loaded system). do/catch
            // (not try?) so a cancelled sleep returns immediately without a stale apply.
            for _ in 0..<20 {
                do { try await ContinuousClock().sleep(for: .milliseconds(150)) } catch { return }
                if mirror.updateClientSize() { return }
            }
        }
    }
}
