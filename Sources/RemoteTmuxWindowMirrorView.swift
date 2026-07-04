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
    @Environment(\.displayScale) private var displayScale
    @State private var sizingRetryTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { geo in
            RemoteTmuxLayoutContainer(
                node: mirror.visibleLayout ?? mirror.layout,
                frames: mirror.framesForRender(containerPt: geo.size),
                mirror: mirror,
                appearance: appearance,
                isVisibleInUI: isVisibleInUI,
                portalPriority: portalPriority,
                onClosePane: onClosePane
            )
            .frame(width: geo.size.width, height: geo.size.height)
            // Sizing is feed-forward: the pushed size is a pure function of
            // these pixels + the base tree's structure + measured constants,
            // so the ONLY events that can change it are the ones below. tmux
            // layout events (geometry echoes, foreign resize-panes) never
            // re-push — f would recompute the identical value, and the
            // per-window dedup on the connection makes even a redundant call
            // free. The view always calls; the MIRROR's gate decides who may write
            // (visible mirrors push; hidden mirrors only their one initial
            // claim — see updateClientSize()). Single-source gating: guarding
            // here too once left hidden windows unclaimed at tmux's 80×24
            // default because the claim path was never reached.
            .onAppear {
                mirror.isVisibleForSizing = isVisibleInUI
                pushClientSize(pointSize: geo.size)
            }
            .onChange(of: geo.size) { _, newSize in
                pushClientSize(pointSize: newSize)
            }
            .onChange(of: isVisibleInUI) { _, visible in
                mirror.isVisibleForSizing = visible
                if visible {
                    // Becoming visible is the re-own point: the remote window
                    // may have been resized (another client, a crash-frozen
                    // pin) while this tab was hidden.
                    pushClientSize(pointSize: geo.size)
                } else {
                    sizingRetryTask?.cancel()
                }
            }
            // Splits/closes change the structure fold's output; geometry-only
            // reflows do not (and never re-arm — see the mirror's invariant).
            .onChange(of: mirror.layoutStructureVersion) { _, _ in
                pushClientSize(pointSize: geo.size)
            }
            .onDisappear { sizingRetryTask?.cancel() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Match the terminal background so the area never shows through as black.
        .background(Color(nsColor: appearance.backgroundColor))
    }

    /// Records the container size and pushes f's output, then keeps re-running
    /// the (deduped, cheap) push for a short window. The revalidation exists
    /// because f's measured constants REFINE after the first push: the surface
    /// pads are min-tracked from live samples, and early samples — taken while
    /// frames are still proportional, not cell-aligned — over-report the pad.
    /// A push made with coarse constants computes one column/row short, and
    /// without this loop nothing re-triggers when the constants settle (tmux
    /// events must never be push triggers — see the mirror's invariant). Each
    /// tick recomputes f from purely local inputs and the per-window dedup
    /// makes converged ticks free, so this stays feed-forward and bounded.
    private func pushClientSize(pointSize: CGSize) {
        mirror.noteContainerSize(pointSize: pointSize, scale: displayScale)
        sizingRetryTask?.cancel()
        _ = mirror.updateClientSize()
        sizingRetryTask = Task { @MainActor in
            for _ in 0..<20 {
                do { try await ContinuousClock().sleep(for: .milliseconds(150)) } catch { return }
                _ = mirror.updateClientSize()
            }
        }
    }
}
