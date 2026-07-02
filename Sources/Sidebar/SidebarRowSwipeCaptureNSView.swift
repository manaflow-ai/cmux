import AppKit

@MainActor
final class SidebarRowSwipeCaptureNSView: NSView {
    var onOffsetChanged: ((CGFloat, Bool) -> Void)?
    var onCommit: ((SidebarRowSwipeGestureModel.Action) -> Void)?

    private var model = SidebarRowSwipeGestureModel()

    override var acceptsFirstResponder: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
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

        let result = model.handle(
            SidebarRowSwipeGestureModel.Event(
                phase: phase,
                scrollingDeltaX: event.scrollingDeltaX,
                scrollingDeltaY: event.scrollingDeltaY
            )
        )
        guard result.claimed else {
            super.scrollWheel(with: event)
            return
        }

        onOffsetChanged?(result.offset, result.shouldAnimateOffset)
        if let commit = result.commit {
            onCommit?(commit)
        }
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
}
