public import AppKit

/// Routes global canvas-style scroll gestures before pane content sees them.
///
/// Canvas and zoomable split layout both need the same precedence: pinch and
/// Option-scroll zoom the outer viewport, Command-scroll pans the outer
/// viewport, and plain scroll remains available to pane content.
@MainActor
public final class CanvasCommandScrollEventRouter {
    private weak var rootView: NSView?
    private weak var scrollView: NSScrollView?
    private let paneViewAtRootPoint: (CGPoint) -> NSView?
    private let handleMagnifyEvent: ((NSEvent) -> Bool)?
    private let handleMagnify: () -> Void
    private let handleOptionScroll: (NSEvent) -> Void
    private let handlePlainScrollInPane: () -> Void
    private var monitor: Any?

    /// Creates a router for one viewport.
    ///
    /// - Parameters:
    ///   - rootView: The view whose bounds scope the gesture monitor.
    ///   - scrollView: The outer viewport that owns pan and magnification.
    ///   - paneViewAtRootPoint: Returns a pane/content view under a point in
    ///     `rootView` coordinates, or `nil` when the point is empty canvas.
    ///   - handleMagnify: Called after a native magnify gesture is forwarded.
    ///   - handleOptionScroll: Called for Option-scroll zoom gestures.
    ///   - handlePlainScrollInPane: Called when plain scroll lands over pane
    ///     content and is passed through.
    public init(
        rootView: NSView,
        scrollView: NSScrollView,
        paneViewAtRootPoint: @escaping (CGPoint) -> NSView?,
        handleMagnifyEvent: ((NSEvent) -> Bool)? = nil,
        handleMagnify: @escaping () -> Void,
        handleOptionScroll: @escaping (NSEvent) -> Void,
        handlePlainScrollInPane: @escaping () -> Void
    ) {
        self.rootView = rootView
        self.scrollView = scrollView
        self.paneViewAtRootPoint = paneViewAtRootPoint
        self.handleMagnifyEvent = handleMagnifyEvent
        self.handleMagnify = handleMagnify
        self.handleOptionScroll = handleOptionScroll
        self.handlePlainScrollInPane = handlePlainScrollInPane
    }

    /// Installs the local event monitor if it is not already active.
    public func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] event in
            guard let self,
                  let rootView = self.rootView,
                  let scrollView = self.scrollView,
                  let window = rootView.window,
                  event.window === window else {
                return event
            }
            let location = rootView.convert(event.locationInWindow, from: nil)
            guard rootView.bounds.contains(location) else { return event }

            if event.type == .magnify {
                if self.handleMagnifyEvent?(event) == true {
                    return nil
                }
                scrollView.magnify(with: event)
                self.handleMagnify()
                return nil
            }

            if event.modifierFlags.contains(.command) {
                scrollView.scrollWheel(with: event)
                return nil
            }

            if event.modifierFlags.contains(.option) {
                self.handleOptionScroll(event)
                return nil
            }

            if self.paneViewAtRootPoint(location) != nil {
                self.handlePlainScrollInPane()
            }
            return event
        }
    }

    /// Removes the local event monitor.
    public func remove() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }
}
