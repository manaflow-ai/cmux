import Bonsplit
import SwiftUI

@MainActor
struct RemoteHerdrWindowMirrorSplitView: View {
    let mirror: RemoteHerdrWindowMirrorHost
    let appearance: PanelAppearance
    let isOuterFocused: Bool
    let isVisibleInUI: Bool
    let portalPriority: Int
    let onOuterFocus: () -> Void
    var unreadSurfaceIDs: Set<UUID> = []
    @Environment(\.displayScale) private var displayScale
    @State private var containerSize: CGSize = .zero

    var body: some View {
        Color(nsColor: appearance.backgroundColor)
            .overlay(alignment: .topLeading) {
                splitTree
            }
            .background(HerdrMirrorHostProbe(mirror: mirror))
            .onGeometryChange(for: CGSize.self) { proxy in
                proxy.size
            } action: { newSize in
                containerSize = newSize
                pushClientSize(pointSize: newSize)
            }
            .onAppear {
                mirror.isVisibleForSizing = isVisibleInUI
                mirror.bonsplitController.isInteractive = isVisibleInUI
                if isVisibleInUI { becameVisible() }
            }
            .onChange(of: isVisibleInUI) { _, visible in
                mirror.isVisibleForSizing = visible
                mirror.bonsplitController.isInteractive = visible
                if visible { becameVisible() }
            }
            .onChange(of: mirror.layoutStructureVersion) { _, _ in
                pushClientSize(pointSize: containerSize)
            }
    }

    private var splitTree: some View {
        BonsplitView(controller: mirror.bonsplitController) { tab, paneId in
            if let herdrPaneId = mirror.herdrPaneId(forTab: tab.id),
               let panel = mirror.panel(forPane: herdrPaneId) {
                TerminalPanelView(
                    panel: panel,
                    paneId: paneId,
                    isFocused: isOuterFocused && mirror.isFocused(tabId: tab.id),
                    isVisibleInUI: isVisibleInUI,
                    portalPaneOwnershipResolver: {
                        mirror.bonsplitController.selectedTab(inPane: paneId)?.id == tab.id
                    },
                    portalPriority: portalPriority,
                    isSplit: true,
                    appearance: appearance,
                    hasUnreadNotification: unreadSurfaceIDs.contains(panel.id),
                    terminalAgentContext: "",
                    onFocus: {
                        onOuterFocus()
                        mirror.setActivePane(herdrPaneId, fromProvider: false)
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
        .frame(
            width: mirror.renderFrameSize?.width,
            height: mirror.renderFrameSize?.height,
            alignment: .topLeading
        )
    }

    private func pushClientSize(pointSize: CGSize) {
        mirror.isVisibleForSizing = isVisibleInUI
        guard pointSize.width > 0, pointSize.height > 0 else { return }
        mirror.noteContainerSize(pointSize: pointSize, scale: displayScale)
    }

    private func becameVisible() {
        pushClientSize(pointSize: containerSize)
        mirror.setNeedsSizingPass()
        mirror.seedActivePaneIfNeeded()
    }
}

/// Zero-cost NSView planted inside the Herdr mirror subtree so the mirror has a
/// window handle that survives portal churn (tmux ``MirrorHostProbe`` analogue).
final class HerdrMirrorHostProbeView: NSView {
    weak var mirror: RemoteHerdrWindowMirrorHost?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        mirror?.setNeedsSizingPass()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else {
            if mirror?.hostProbeView === self { mirror?.hostProbeView = nil }
            return
        }
        mirror?.hostProbeView = self
    }
}

private struct HerdrMirrorHostProbe: NSViewRepresentable {
    let mirror: RemoteHerdrWindowMirrorHost

    func makeNSView(context: Context) -> HerdrMirrorHostProbeView {
        let view = HerdrMirrorHostProbeView()
        view.mirror = mirror
        mirror.hostProbeView = view
        return view
    }

    func updateNSView(_ nsView: HerdrMirrorHostProbeView, context: Context) {
        nsView.mirror = mirror
        mirror.hostProbeView = nsView
    }
}
