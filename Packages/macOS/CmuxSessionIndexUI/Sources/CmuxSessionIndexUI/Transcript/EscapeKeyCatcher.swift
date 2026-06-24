public import SwiftUI

/// A zero-size view that invokes `onEscape` when Escape is pressed while its window is key.
///
/// Backed by a local AppKit key-down monitor scoped to the hosting window. Used by the
/// transcript preview (and the app-side "Show more" session popover) to dismiss on Escape.
/// `public` so the app can keep using it after the move; it could move to
/// `CmuxAppKitSupportUI` if another package needs it.
public struct EscapeKeyCatcher: NSViewRepresentable {
    private let onEscape: () -> Void

    /// Creates a catcher that invokes `onEscape` on the Escape key.
    public init(onEscape: @escaping () -> Void) {
        self.onEscape = onEscape
    }

    public func makeNSView(context: Context) -> NSView {
        let view = EscapeMonitorView()
        view.onEscape = onEscape
        return view
    }

    public func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? EscapeMonitorView)?.onEscape = onEscape
    }

    private final class EscapeMonitorView: NSView {
        var onEscape: (() -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let win = self.window, win.isKeyWindow else { return event }
                if event.keyCode == 53 {
                    self.onEscape?()
                    return nil
                }
                return event
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}
