import SwiftUI

/// Renders a mirrored tmux window's multi-pane layout as nested splits inside a
/// single cmux tab. Each pane is a real ``TerminalPanel`` (rendered via
/// ``TerminalPanelView`` for native chrome) topped with a small control header
/// (split / close) that doubles as a clearly visible separator between panes.
@MainActor
struct RemoteTmuxWindowMirrorView: View {
    let mirror: RemoteTmuxWindowMirror
    let appearance: PanelAppearance
    let isFocused: Bool
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
                isFocused: isFocused,
                isVisibleInUI: isVisibleInUI,
                portalPriority: portalPriority,
                onClosePane: onClosePane
            )
            .frame(width: geo.size.width, height: geo.size.height)
            // Size the remote tmux window to the rendered area so pane content
            // matches the on-screen grid.
            .onAppear { scheduleClientSize(geo.size) }
            .onChange(of: geo.size) { _, newSize in scheduleClientSize(newSize) }
            .onDisappear { sizingRetryTask?.cancel() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Match the terminal background so the area never shows through as black.
        .background(Color(nsColor: appearance.backgroundColor))
    }

    /// Pushes the client size to tmux, retrying briefly while the pane surface hasn't
    /// reported its cell size yet — so the initial `refresh-client -C` lands even when
    /// the view size never changes after attach. Each call restarts the retry with the
    /// LATEST size, so a resize arriving before the surface is live isn't lost and can't
    /// be overwritten by a stale earlier size. `updateClientSize` dedups + reports
    /// readiness, so the retry stops as soon as the surface goes live.
    private func scheduleClientSize(_ size: CGSize) {
        sizingRetryTask?.cancel()
        if mirror.updateClientSize(contentSizePoints: size) { return }
        sizingRetryTask = Task { @MainActor in
            // Retry until the pane surface reports its cell size (local layout timing,
            // normally a frame or two; budget generously for a loaded system). do/catch
            // (not try?) so a cancelled sleep returns immediately without a stale apply.
            for _ in 0..<20 {
                do { try await ContinuousClock().sleep(for: .milliseconds(150)) } catch { return }
                if mirror.updateClientSize(contentSizePoints: size) { return }
            }
        }
    }
}
