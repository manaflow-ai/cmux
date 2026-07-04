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
            .onAppear { refreshClientSize() }
            .onChange(of: geo.size) { _, _ in refreshClientSize() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Match the terminal background so the area never shows through as black.
        .background(Color(nsColor: appearance.backgroundColor))
    }

    /// Makes one synchronous sizing attempt. If any pane has not produced an
    /// on-screen grid yet, each surface's `onManualGridResize` callback triggers
    /// the next attempt when that grid becomes readable.
    private func refreshClientSize() {
        _ = mirror.updateClientSize()
    }
}
