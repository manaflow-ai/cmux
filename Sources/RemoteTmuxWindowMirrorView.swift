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
            // matches the on-screen grid. `geo.size` is the trigger to re-evaluate;
            // `updateClientSize` reads the panes' rendered grids for the real size.
            .onAppear { scheduleClientSize() }
            .onChange(of: geo.size) { _, _ in scheduleClientSize() }
            .onDisappear { sizingRetryTask?.cancel() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Match the terminal background so the area never shows through as black.
        .background(Color(nsColor: appearance.backgroundColor))
    }

    /// Pushes the client size to tmux, retrying briefly while the pane surfaces
    /// haven't rendered their grids yet — so the initial `refresh-client -C` lands
    /// even when the view size never changes after attach. Live resizes afterwards
    /// flow through each pane surface's `onManualGridResize` hook (race-free: the
    /// surface reports after applying its grid), so this is the initial-push path;
    /// `updateClientSize` dedups + reports readiness, so the retry stops as soon as
    /// the panes go live.
    private func scheduleClientSize() {
        sizingRetryTask?.cancel()
        if mirror.updateClientSize() { return }
        sizingRetryTask = Task { @MainActor in
            // Retry until every pane surface reports its rendered grid (local layout
            // timing, normally a frame or two; budget generously for a loaded system).
            // do/catch (not try?) so a cancelled sleep returns immediately.
            for _ in 0..<20 {
                do { try await ContinuousClock().sleep(for: .milliseconds(150)) } catch { return }
                if mirror.updateClientSize() { return }
            }
        }
    }
}
