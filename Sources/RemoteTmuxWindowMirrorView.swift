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
    /// The container size, fed by `onGeometryChange` (an event, not a layout
    /// read) — the render derives frames from it, and every change re-runs
    /// the deduped client-size push.
    @State private var containerSize: CGSize = .zero

    var body: some View {
        RemoteTmuxLayoutContainer(
            node: mirror.visibleLayout ?? mirror.layout,
            frames: containerSize == .zero ? nil : mirror.framesForRender(containerPt: containerSize),
            mirror: mirror,
            appearance: appearance,
            isVisibleInUI: isVisibleInUI,
            portalPriority: portalPriority,
            onClosePane: onClosePane
        )
        // topLeading, not the default center: if the pane tree is mid-transition
        // and briefly bigger than this frame, overflow must clip at the trailing
        // edge (tmux coordinates are absolute from the top-left), not shift
        // every pane by half the difference.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Match the terminal background so the area never shows through as black.
        .background(Color(nsColor: appearance.backgroundColor))
        // Sizing is feed-forward: the pushed size is a pure function of these
        // pixels + the base tree's structure + measured constants, so the
        // only push triggers are the events below plus each surface's
        // grid-resize report (see reconcile) — the moment measured constants
        // can change. tmux layout events never re-push: f would recompute
        // the identical value, and per-window dedup makes a redundant call
        // free. The view always calls; the MIRROR's gate decides who may
        // write (visible mirrors push; hidden mirrors only their one initial
        // claim — see updateClientSize()).
        .onGeometryChange(for: CGSize.self) { proxy in
            proxy.size
        } action: { newSize in
            containerSize = newSize
            pushClientSize(pointSize: newSize)
        }
        .onAppear {
            mirror.isVisibleForSizing = isVisibleInUI
        }
        .onChange(of: isVisibleInUI) { _, visible in
            mirror.isVisibleForSizing = visible
            if visible {
                // Becoming visible is the re-own point: the remote window
                // may have been resized (another client, a crash-frozen
                // pin) while this tab was hidden.
                pushClientSize(pointSize: containerSize)
            }
        }
        // Splits/closes change the structure fold's output; geometry-only
        // reflows do not (and never re-arm — see the mirror's invariant).
        .onChange(of: mirror.layoutStructureVersion) { _, _ in
            pushClientSize(pointSize: containerSize)
        }
    }

    /// Records the container size and runs the deduped push. No retry loop:
    /// while the render constants are still unknown the push is a no-op, and
    /// the surface's first grid-resize report (wired in the mirror's
    /// reconcile) re-runs it the moment constants exist.
    private func pushClientSize(pointSize: CGSize) {
        guard pointSize.width > 0, pointSize.height > 0 else { return }
        mirror.noteContainerSize(pointSize: pointSize, scale: displayScale)
        _ = mirror.updateClientSize()
    }
}
