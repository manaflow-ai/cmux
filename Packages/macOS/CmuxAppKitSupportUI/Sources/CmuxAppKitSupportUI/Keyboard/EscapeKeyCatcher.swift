import AppKit
public import SwiftUI

/// Invisible AppKit view that fires `onEscape` when Escape is pressed while
/// the host view's window is key. Lives in the view tree so it inherits
/// the surrounding popover/window responder chain.
public struct EscapeKeyCatcher: NSViewRepresentable {
    public let onEscape: () -> Void

    /// Creates an Escape-key catcher.
    /// - Parameter onEscape: Invoked when Escape is pressed while the host window is key.
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
