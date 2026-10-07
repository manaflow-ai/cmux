import AppKit
import CmuxNextBridge
import CmuxNextDesign
import CmuxNextSidebar
import CmuxNextTabs

/// DRAG-SHAPE-INVARIANT (decisions.md, Lawrence 2026-10-07) for one
/// `TabDragSession` drag: the drag keeps its own shape over a surface that
/// takes it in place (any tab strip for a tab, any sidebar list for a
/// workspace) and is the preview card everywhere else. `DragShapeMachine`
/// decides; this feeds it from the session's hit tests and keeps the held
/// surface first while the pointer is inside that surface's own leave
/// distance (strip tear-off, sidebar side slack), so the boundary is the
/// same before and after the source surface hands the drag over, in every
/// window.
@MainActor
struct DragShapeTracker {
    private(set) var machine = DragShapeMachine()
    /// The held surface: a strip (tabs) in `heldWindow`, or `heldWindow`'s
    /// sidebar list (workspaces).
    private(set) weak var heldStrip: TabStripView?
    private(set) weak var heldWindow: WindowController?

    var shape: DragShape { machine.shape }

    // MARK: Tabs

    /// The held strip's proposal while the pointer is inside its leave band,
    /// asked at the pointer clamped into the strip, recorded as touched by
    /// `drag`. Nil: hit-test normally.
    func heldStripHit(_ point: CGPoint, payload: TabDragPayload, drag: TabDragSession.Drag)
        -> (strip: TabStripView, window: WindowController, proposal: TabDropProposal)? {
        guard let probe = machine.stickyProbe(point), let heldStrip, let heldWindow,
              let proposal = heldStrip.dropHitTest(screenPoint: probe.point, payload: payload) else { return nil }
        drag.noTargetReason = nil
        drag.touched[ObjectIdentifier(heldStrip)] = heldStrip
        return (heldStrip, heldWindow, proposal)
    }

    /// Feeds a tab drag's winner: in place when a strip takes the tab (a
    /// move or its own place), the card for every other surface.
    mutating func resolveTab(_ winner: (provider: any TabDropTargetProviding, proposal: TabDropProposal)?, window: WindowController?,
                             preview: TabDropPreview) {
        var answer: DragShapeAnswer?
        let provider = winner?.provider
        if let strip = provider as? TabStripView, let slot = winner?.proposal.ghostFrame, let bounds = Self.screenFrame(of: strip) {
            let accepts: Bool = switch preview {
            case .target, .stay: true
            case .refused, .newWindow, .none: false
            }
            let target = DragShapeTarget(key: "strip-\(ObjectIdentifier(strip).hashValue)", bounds: bounds, axis: .horizontal,
                                         leaveMargin: strip.metrics.tearOffDistance)
            answer = DragShapeAnswer(target: target, slot: slot, accepts: accepts)
        }
        machine.resolve(answer)
        heldStrip = machine.held == nil ? nil : provider as? TabStripView
        heldWindow = machine.held == nil ? nil : window
    }

    // MARK: Workspaces

    /// The window whose sidebar list asks first, and the point to ask it at,
    /// while the pointer is inside the held list's side slack.
    func heldSidebarProbe(_ point: CGPoint) -> (window: WindowController, point: CGPoint)? {
        guard let probe = machine.stickyProbe(point), heldStrip == nil, let heldWindow else { return nil }
        return (heldWindow, probe.point)
    }

    /// Feeds a workspace drag's sidebar hit (the window and its lit slot; nil
    /// when no sidebar list answered): in place when a list takes the
    /// workspaces (a slot, a group, a row), the card over content, on a
    /// refusal and outside.
    mutating func resolveWorkspace(_ hit: (window: WindowController, slot: CGRect?)?, outcome: WorkspaceDragOutcome) {
        var answer: DragShapeAnswer?
        let window = hit?.window
        if let window, let slot = hit?.slot, let bounds = Self.screenFrame(of: window.sidebar.container.sidebarView) {
            let target = DragShapeTarget(key: "sidebar-\(window.state.id)", bounds: bounds, axis: .vertical,
                                         leaveMargin: SidebarView.handoffSlack)
            let accepts: Bool = switch outcome {
            case .window(_, .position), .window(_, .intoGroup), .window(_, .window): true
            case .window(_, .merge), .newWindow, .moveWindow, .cancel: false
            }
            answer = DragShapeAnswer(target: target, slot: slot, accepts: accepts)
        }
        machine.resolve(answer)
        heldStrip = nil
        heldWindow = machine.held == nil ? nil : window
    }

    // MARK: Presentation

    /// The ghost's item rect and presentation for `drag` now.
    func ghostTarget(of drag: TabDragSession.Drag) -> (rect: CGRect, presentation: TabDragSession.Presentation) {
        let rect = DragShapeMachine.itemRect(shape, pointer: drag.point, grabOffset: drag.source.grabOffset,
                                             itemSize: drag.source.screenFrame.size)
        if case .inPlace(_, let slot) = shape { return (rect, .inline(slot)) }
        return (rect, .card)
    }

    /// Where an in-place drop lands: the slot, at the item's height. Nil as a card.
    func landingRect(height: CGFloat) -> CGRect? {
        guard case .inPlace(_, let slot) = shape else { return nil }
        return CGRect(x: slot.minX, y: slot.midY - height / 2, width: slot.width, height: height)
    }

    static func screenFrame(of view: NSView) -> CGRect? {
        guard let window = view.window, !view.isHiddenOrHasHiddenAncestor else { return nil }
        return window.convertToScreen(view.convert(view.bounds, to: nil))
    }
}
