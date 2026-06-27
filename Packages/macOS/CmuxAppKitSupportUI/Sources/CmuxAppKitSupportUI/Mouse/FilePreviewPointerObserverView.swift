public import AppKit

/// Backing `NSView` for ``FilePreviewPointerObserver`` that runs `onPointerDown`
/// when a left-mouse-down lands inside its bounds.
///
/// Uses a local `.leftMouseDown` event monitor scoped to its own window and
/// bounds, so the observer reports pointer focus without consuming the click;
/// ``hitTest(_:)`` returns `nil` so the event still hit-tests through to the
/// underlying preview content. The callback is deferred to the main queue to
/// avoid mutating focus state inside the event-monitor pass.
public final class FilePreviewPointerObserverView: NSView {
    /// Invoked when a left-mouse-down lands inside this view's bounds.
    public var onPointerDown: (() -> Void)?
    private var eventMonitor: Any?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            guard let self,
                  event.window === self.window,
                  !self.isHiddenOrHasHiddenAncestor else { return event }
            let point = self.convert(event.locationInWindow, from: nil)
            if self.bounds.contains(point) {
                DispatchQueue.main.async { [weak self] in
                    self?.onPointerDown?()
                }
            }
            return event
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
    }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
