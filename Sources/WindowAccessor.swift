import AppKit
import SwiftUI

struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void
    let dedupeByWindow: Bool

    init(dedupeByWindow: Bool = true, onWindow: @escaping (NSWindow) -> Void) {
        self.onWindow = onWindow
        self.dedupeByWindow = dedupeByWindow
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WindowObservingView {
        let view = WindowObservingView()
        view.onWindow = { window in
            guard !dedupeByWindow || context.coordinator.lastWindow !== window else { return }
            context.coordinator.lastWindow = window
            onWindow(window)
        }
        return view
    }

    func updateNSView(_ nsView: WindowObservingView, context: Context) {
        nsView.onWindow = { window in
            guard !dedupeByWindow || context.coordinator.lastWindow !== window else { return }
            context.coordinator.lastWindow = window
            onWindow(window)
        }
        if let window = nsView.window {
            nsView.onWindow?(window)
        }
    }
}

extension WindowAccessor {
    final class Coordinator {
        weak var lastWindow: NSWindow?
    }
}

final class WindowObservingView: NSView {
    var onWindow: ((NSWindow) -> Void)?

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if let newWindow {
            onWindow?(newWindow)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            onWindow?(window)
        }
    }
}
