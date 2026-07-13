import Bonsplit
import SwiftUI

@MainActor
struct RemoteTmuxWindowMirrorSplitView: View {
    let mirror: RemoteTmuxWindowMirror
    let appearance: PanelAppearance
    let isOuterFocused: Bool
    let isVisibleInUI: Bool
    let portalPriority: Int
    let onOuterFocus: () -> Void
    @Environment(\.displayScale) private var displayScale
    @State private var containerSize: CGSize = .zero

    var body: some View {
        BonsplitView(controller: mirror.bonsplitController) { tab, paneId in
            if let tmuxPaneId = mirror.tmuxPaneId(forTab: tab.id),
               let panel = mirror.panel(forPane: tmuxPaneId) {
                TerminalPanelView(
                    panel: panel,
                    paneId: paneId,
                    isFocused: isOuterFocused && mirror.isFocused(tabId: tab.id),
                    isVisibleInUI: isVisibleInUI,
                    portalPriority: portalPriority,
                    isSplit: true,
                    appearance: appearance,
                    hasUnreadNotification: false,
                    terminalAgentContext: "",
                    onFocus: {
                        onOuterFocus()
                        mirror.setActivePane(tmuxPaneId, fromTmux: false)
                    },
                    onResumeAgentHibernation: {},
                    onAutoResumeAgentHibernation: {},
                    onTriggerFlash: {}
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onTapGesture {
                    onOuterFocus()
                    mirror.bonsplitController.focusPane(paneId)
                }
            } else {
                Color(nsColor: appearance.backgroundColor)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } emptyPane: { _ in
            Color(nsColor: appearance.backgroundColor)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .internalOnlyTabDrag()
        // The tree renders at its exact grid-plus-chrome size; the region's
        // sub-cell remainder stays outside it as trailing margin (painted by
        // the background below), so no pane inherits a fraction of a cell
        // along a split axis and rounds onto an extra row or column. nil
        // (before the first sized pass) falls back to filling the region.
        .frame(
            width: mirror.renderFrameSize?.width,
            height: mirror.renderFrameSize?.height,
            alignment: .topLeading
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: appearance.backgroundColor))
        .background(MirrorHostProbe(mirror: mirror))
        .onGeometryChange(for: CGSize.self) { proxy in
            proxy.size
        } action: { newSize in
            containerSize = newSize
            pushClientSize(pointSize: newSize)
        }
        .onAppear {
            mirror.isVisibleForSizing = isVisibleInUI
            if isVisibleInUI { becameVisible() }
        }
        .onChange(of: isVisibleInUI) { _, visible in
            mirror.isVisibleForSizing = visible
            if visible { becameVisible() }
        }
        .onChange(of: mirror.layoutStructureVersion) { _, _ in
            pushClientSize(pointSize: containerSize)
        }
    }

    private func pushClientSize(pointSize: CGSize) {
        mirror.isVisibleForSizing = isVisibleInUI
        guard pointSize.width > 0, pointSize.height > 0 else { return }
        mirror.noteContainerSize(pointSize: pointSize, scale: displayScale)
    }

    /// A tab shown again may have had its views recreated while hidden, so
    /// identical sizing inputs do not mean the fresh views hold the plan —
    /// request the pass that ignores the settled check.
    private func becameVisible() {
        pushClientSize(pointSize: containerSize)
        mirror.setNeedsSizingPassIgnoringInputs()
    }
}

/// Plants a zero-cost NSView inside the mirror's own view subtree so the
/// mirror has a window handle that survives portal churn, and an ancestor
/// chain rooted at the mirror's real position for geometry diagnostics.
private struct MirrorHostProbe: NSViewRepresentable {
    let mirror: RemoteTmuxWindowMirror

    final class ProbeView: NSView {
        weak var mirror: RemoteTmuxWindowMirror?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            mirror?.hostProbeView = self
        }
    }

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.mirror = mirror
        mirror.hostProbeView = view
        return view
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        nsView.mirror = mirror
        mirror.hostProbeView = nsView
    }
}
