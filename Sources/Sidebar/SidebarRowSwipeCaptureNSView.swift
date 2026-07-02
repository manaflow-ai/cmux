import AppKit

@MainActor
final class SidebarRowSwipeCaptureNSView: NSView {
    var workspaceId: UUID {
        didSet {
#if DEBUG
            guard workspaceId != oldValue, window != nil else { return }
            AppDelegate.shared?.sidebarRowSwipeDebugRegistry.unregister(workspaceId: oldValue, view: self)
            AppDelegate.shared?.sidebarRowSwipeDebugRegistry.register(workspaceId: workspaceId, view: self)
#endif
        }
    }

    var onOffsetChanged: ((CGFloat, Bool) -> Void)?
    var onCommit: ((SidebarRowSwipeGestureModel.Action) -> Void)?

    private var model = SidebarRowSwipeGestureModel()

    override var acceptsFirstResponder: Bool { false }

    init(workspaceId: UUID, frame frameRect: NSRect) {
        self.workspaceId = workspaceId
        super.init(frame: frameRect)
        wantsLayer = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
#if DEBUG
        if window == nil {
            AppDelegate.shared?.sidebarRowSwipeDebugRegistry.unregister(workspaceId: workspaceId, view: self)
        } else {
            AppDelegate.shared?.sidebarRowSwipeDebugRegistry.register(workspaceId: workspaceId, view: self)
        }
#endif
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard NSApp.currentEvent?.type == .scrollWheel else { return nil }
        return super.hitTest(point)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let phase = Self.phase(for: event) else {
            super.scrollWheel(with: event)
            return
        }

        let result = handle(phase: phase, deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY)
        guard result.claimed else {
            super.scrollWheel(with: event)
            return
        }
    }

    private func handle(
        phase: SidebarRowSwipeGestureModel.Phase,
        deltaX: CGFloat,
        deltaY: CGFloat
    ) -> SidebarRowSwipeGestureModel.Result {
        let result = model.handle(
            SidebarRowSwipeGestureModel.Event(
                phase: phase,
                scrollingDeltaX: deltaX,
                scrollingDeltaY: deltaY
            )
        )
        guard result.claimed else { return result }

        onOffsetChanged?(result.offset, result.shouldAnimateOffset)
        if let commit = result.commit {
            onCommit?(commit)
        }
        return result
    }

    private static func phase(for event: NSEvent) -> SidebarRowSwipeGestureModel.Phase? {
        if !event.momentumPhase.isEmpty {
            return .momentum
        }

        let phase = event.phase
        if phase.contains(.cancelled) {
            return .cancelled
        }
        if phase.contains(.ended) {
            return .ended
        }
        if phase.contains(.began) {
            return .began
        }
        if phase.contains(.changed) || phase.contains(.stationary) || phase.isEmpty {
            return .changed
        }
        return nil
    }

#if DEBUG
    func debugSimulateSwipe(_ action: SidebarRowSwipeDebugRegistry.Action) -> SidebarRowSwipeDebugRegistry.Result {
        var committed = false
        var offset: CGFloat = 0
        var released = false

        for event in debugEvents(for: action) {
            let result = handle(phase: event.phase, deltaX: event.deltaX, deltaY: event.deltaY)
            committed = committed || result.commit != nil
            offset = result.offset
            released = event.phase == .ended || event.phase == .cancelled
        }

        return SidebarRowSwipeDebugRegistry.Result(
            committed: committed,
            offset: offset,
            released: released
        )
    }

    private func debugEvents(
        for action: SidebarRowSwipeDebugRegistry.Action
    ) -> [(phase: SidebarRowSwipeGestureModel.Phase, deltaX: CGFloat, deltaY: CGFloat)] {
        switch action {
        case .revealLeading:
            return [
                (.began, 0, 0),
                (.changed, 20, 0),
                (.changed, 20, 0),
                (.changed, 20, 0),
                (.changed, 20, 0),
            ]
        case .revealTrailing:
            return [
                (.began, 0, 0),
                (.changed, -20, 0),
                (.changed, -20, 0),
                (.changed, -20, 0),
                (.changed, -20, 0),
            ]
        case .commitLeading:
            return [
                (.began, 0, 0),
                (.changed, 40, 0),
                (.changed, 40, 0),
                (.ended, 0, 0),
            ]
        case .commitTrailing:
            return [
                (.began, 0, 0),
                (.changed, -40, 0),
                (.changed, -40, 0),
                (.ended, 0, 0),
            ]
        case .release:
            // Cancelled, not ended: reveal sequences sit past the commit
            // threshold, and release must always snap back without committing.
            return [
                (.cancelled, 0, 0),
            ]
        }
    }
#endif
}
