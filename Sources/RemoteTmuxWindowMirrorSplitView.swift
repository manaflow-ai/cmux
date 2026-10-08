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
    var unreadSurfaceIDs: Set<UUID> = []

    var body: some View {
        // The base color is the region, and it answers every proposal with
        // the proposal; the split tree renders in the overlay at its exact
        // grid-plus-chrome size. The two are separated because they disagree
        // under churn: the tree's frame is derived from the BANKED container
        // while the proposal comes from the live window, so a window shrink
        // leaves the tree momentarily wider than the region. In an overlay
        // the excess overflows in place. Sizing the tree inline let it leak —
        // a flexible frame with no minWidth reports its CHILD's width when
        // the child exceeds the proposal — so the imposed width became this
        // view's reported size, every space-filling ancestor up to the main
        // window's root content inherited it (observed live: the content
        // view marching wider than the display-pinned window a step per
        // layout pass), and geometry reporting then read the
        // mirror's own imposed width back as its "container".
        Color(nsColor: appearance.backgroundColor)
            .overlay(alignment: .topLeading) {
                splitTree
            }
            .background(MirrorHostProbe(mirror: mirror))
            .onAppear {
                mirror.isVisibleForSizing = isVisibleInUI
                if !isVisibleInUI {
                    mirror.cancelPendingControlPaneFocus()
                    mirror.cancelPendingCreatedPaneFocus()
                }
                // The workspace keeps every tab's content alive and hides
                // deselected tabs at SwiftUI opacity 0, which never reaches
                // the AppKit split tree this mirror renders: the hidden
                // trees kept painting dividers over the visible panes,
                // registering resize-cursor rects, and stacking alpha-0
                // drop zones that rejected pane drops. isInteractive is
                // bonsplit's AppKit-level switch (it sets isHidden on the
                // split tree), so it follows the same visibility edge.
                mirror.bonsplitController.isInteractive = isVisibleInUI
                if isVisibleInUI { becameVisible() }
            }
            .onChange(of: isVisibleInUI) { _, visible in
                mirror.isVisibleForSizing = visible
                if !visible {
                    mirror.cancelPendingControlPaneFocus()
                    mirror.cancelPendingCreatedPaneFocus()
                }
                mirror.bonsplitController.isInteractive = visible
                if visible { becameVisible() }
            }
            .onChange(of: mirror.layoutStructureVersion) { _, _ in
                mirror.refreshContainerSizeFromHost()
                mirror.setNeedsSizingPass()
            }
    }

    private var splitTree: some View {
        BonsplitView(controller: mirror.bonsplitController) { tab, paneId in
            if let tmuxPaneId = mirror.tmuxPaneId(forTab: tab.id),
               let panel = mirror.panel(forPane: tmuxPaneId) {
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
        // the base color), so no pane inherits a fraction of a cell along a
        // split axis and rounds onto an extra row or column. nil (before the
        // first sized pass) falls back to filling the region — the overlay
        // proposes the base's size.
        .frame(
            width: mirror.renderFrameSize?.width,
            height: mirror.renderFrameSize?.height,
            alignment: .topLeading
        )
    }

    /// A tab shown again may have had its views recreated while hidden, so
    /// identical sizing inputs do not mean the fresh views hold the plan —
    /// request the pass that ignores the settled check.
    private func becameVisible() {
        mirror.refreshContainerSizeFromHost()
        mirror.setNeedsSizingPassIgnoringInputs()
    }
}

/// The NSView ``MirrorHostProbe`` plants inside the mirror's own
/// view subtree so the mirror has a window handle that survives portal
/// churn, and an ancestor chain rooted at the mirror's real position for
/// geometry diagnostics.
final class MirrorHostProbeView: NSView {
    weak var mirror: RemoteTmuxWindowMirror?
    /// Region changes can finish after a display change or outside live resize.
    /// AppKit's actual frame supplies the measurement, without a queue delay.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        mirror?.noteHostProbeGeometry(self)
    }

    override func setBoundsSize(_ newSize: NSSize) {
        super.setBoundsSize(newSize)
        mirror?.noteHostProbeGeometry(self)
    }

    override func layout() {
        super.layout()
        mirror?.noteHostProbeGeometry(self)
    }

    /// A scale-only display move does not change the region's point size.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        mirror?.refreshContainerSizeFromHost()
    }

    /// The probe backs the whole mirror region, including the sub-cell
    /// margin outside the split tree; it must never swallow a click there.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        // A window live-resize whose final geometry arrived BEFORE mouse-up
        // leaves a parked oversized reading with no edge to consume it —
        // the host geometry can already be final, and the parked-reading
        // consumer holds while inLiveResize is true. By the time this
        // coalesced pass runs, inLiveResize is false so the consume proceeds.
        // setNeedsSizingPass (not IgnoringInputs): the consume sits above the
        // inputs == lastCompletedSizingInputs check.
        mirror?.setNeedsSizingPass()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else {
            // A tab re-show can recreate the probe, and AppKit delivers the
            // DYING probe's move-to-nil-window after the replacement already
            // registered — claiming here would shadow the live probe's
            // window handle with a windowless view until the next SwiftUI
            // update. Only the currently registered probe may clear the
            // slot; a stale probe changes nothing.
            if mirror?.hostProbeView === self { mirror?.hostProbeView = nil }
            return
        }
        mirror?.hostProbeView = self
        mirror?.noteHostProbeGeometry(self)
    }
}

private struct MirrorHostProbe: NSViewRepresentable {
    let mirror: RemoteTmuxWindowMirror

    func makeNSView(context: Context) -> MirrorHostProbeView {
        let view = MirrorHostProbeView()
        view.mirror = mirror
        mirror.hostProbeView = view
        return view
    }

    func updateNSView(_ nsView: MirrorHostProbeView, context: Context) {
        nsView.mirror = mirror
        mirror.hostProbeView = nsView
        mirror.noteHostProbeGeometry(nsView)
    }
}

extension RemoteTmuxWindowMirror {
    /// Reveal and topology changes sample the current host instead of replaying
    /// a SwiftUI measurement captured before a display move.
    func refreshContainerSizeFromHost() {
        guard let probe = hostProbeView else { return }
        // This can run inside SwiftUI/AppKit layout. Later frame and layout
        // callbacks deliver final geometry without recursively forcing layout.
        noteHostProbeGeometry(probe)
    }

    /// Only the registered, attached probe can deliver geometry. Repeated
    /// AppKit callbacks share the model's accepted or pending measurement.
    func noteHostProbeGeometry(_ probe: NSView) {
        guard hostProbeView === probe, let window = probe.window else { return }
        let size = probe.bounds.size
        let scale = window.backingScaleFactor
        let latestSize = pendingOversizedReading?.size ?? pendingContainerSizePt ?? containerSizePt
        let latestScale = pendingOversizedReading?.scale ?? pendingContainerScale ?? containerScale
        guard latestSize != size || latestScale != scale else { return }
        noteContainerSize(pointSize: size, scale: scale)
    }
}
