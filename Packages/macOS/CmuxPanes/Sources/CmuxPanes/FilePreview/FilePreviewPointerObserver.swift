public import AppKit
public import SwiftUI

/// A passthrough SwiftUI overlay that reports a pointer-down inside its bounds
/// without consuming the click.
///
/// It installs a local `.leftMouseDown` monitor and invokes `onPointerDown`
/// whenever a left mouse-down lands inside the view's bounds in its own window,
/// while `hitTest(_:)` always returns `nil` so the event continues to the view
/// beneath. Used by the file preview to claim panel focus on interaction.
public struct FilePreviewPointerObserver: NSViewRepresentable {
    /// Invoked on the main queue after a left mouse-down inside the view's bounds.
    public let onPointerDown: () -> Void

    /// Creates a pointer observer that reports left mouse-downs without consuming them.
    public init(onPointerDown: @escaping () -> Void) {
        self.onPointerDown = onPointerDown
    }

    public func makeNSView(context: Context) -> FilePreviewPointerObserverView {
        let view = FilePreviewPointerObserverView()
        view.onPointerDown = onPointerDown
        return view
    }

    public func updateNSView(_ nsView: FilePreviewPointerObserverView, context: Context) {
        nsView.onPointerDown = onPointerDown
    }
}

/// The click-through `NSView` backing ``FilePreviewPointerObserver``.
///
/// Holds the local mouse-down monitor for its lifetime and forwards in-bounds
/// left mouse-downs to `onPointerDown`. `hitTest(_:)` returns `nil`
/// unconditionally so the view never captures the click it observes.
public final class FilePreviewPointerObserverView: NSView {
    /// Invoked on the main queue after a left mouse-down inside this view's bounds.
    public var onPointerDown: (() -> Void)?
    private nonisolated(unsafe) var eventMonitor: Any?

    /// Creates the observer view and installs the local mouse-down monitor.
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
