import AppKit
public import SwiftUI

/// Invisible AppKit view that runs `onCancel` after any `mouseUp` OR Escape
/// keypress while a drag is in progress, so a cancelled drag (user releases
/// outside any valid drop target, or presses Esc mid-drag) doesn't leave the
/// dragged element stuck in its dragging appearance.
///
/// `isDragActive` reports whether a drag is currently in progress; the monitor
/// is inert while it returns `false`. The clear is deferred to the main queue so
/// any successful-drop handler already queued on the main actor wins the race
/// against this fallback; this path only matters when no drop fires, i.e. the
/// drag was cancelled. The deferred block captures `onCancel` (not the view), so
/// the clear still runs even if the host view goes away first.
///
/// Mirrors ``EscapeKeyCatcher``: a thin `NSViewRepresentable` over a single
/// `NSEvent` local monitor wired to closure seams, with no reference to the
/// caller's drag-state model.
public struct DragCancelMonitor: NSViewRepresentable {
    /// Returns whether a drag is currently in progress.
    public let isDragActive: () -> Bool
    /// Clears the in-progress drag state.
    public let onCancel: () -> Void

    /// Creates a drag-cancel monitor.
    /// - Parameters:
    ///   - isDragActive: Returns `true` while a drag is in progress; the monitor
    ///     is inert otherwise.
    ///   - onCancel: Invoked (deferred to the main queue) when a drag is
    ///     cancelled by a mouse release or Escape keypress.
    public init(isDragActive: @escaping () -> Bool, onCancel: @escaping () -> Void) {
        self.isDragActive = isDragActive
        self.onCancel = onCancel
    }

    public func makeNSView(context: Context) -> NSView {
        let view = DragCancelMonitorView()
        view.isDragActive = isDragActive
        view.onCancel = onCancel
        return view
    }

    public func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? DragCancelMonitorView else { return }
        view.isDragActive = isDragActive
        view.onCancel = onCancel
    }

    private final class DragCancelMonitorView: NSView {
        var isDragActive: (() -> Bool)?
        var onCancel: (() -> Void)?
        // The token is set/cleared only on the main thread (this is a
        // main-thread AppKit view); the lone cross-isolation read is its
        // removal in the nonisolated deinit, which runs after all main-thread
        // access has ceased, so `nonisolated(unsafe)` is safe here.
        private nonisolated(unsafe) var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
            guard window != nil else { return }
            // Cover every way a drag can end without a drop firing:
            // mouse release (default cancellation) and Escape (AppKit
            // signals drag abort by delivering a keyDown with
            // kVK_Escape / keyCode 53). Without the Escape branch,
            // pressing Esc to cancel a drag leaves the dragged element
            // stuck in its dragging appearance until the next mouseUp elsewhere.
            monitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseUp, .otherMouseUp, .keyDown]
            ) { [weak self] event in
                guard let self,
                      let isDragActive = self.isDragActive,
                      isDragActive() else { return event }
                if event.type == .keyDown, event.keyCode != 53 { // 53 = kVK_Escape
                    return event
                }
                // Defer the clear so any drop handler already queued on the
                // main actor wins first; this path only matters when no drop
                // fires, i.e. the drag was cancelled.
                let onCancel = self.onCancel
                DispatchQueue.main.async {
                    onCancel?()
                }
                return event
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}
