import AppKit
import SwiftUI

// MARK: - WindowAccessor

struct WindowAccessor: NSViewRepresentable {
    // MARK: Properties

    let onWindow: (NSWindow) -> Void
    let dedupeByWindow: Bool

    // MARK: Lifecycle

    init(dedupeByWindow: Bool = true, onWindow: @escaping (NSWindow) -> Void) {
        self.onWindow = onWindow
        self.dedupeByWindow = dedupeByWindow
    }

    // MARK: Functions

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

// MARK: WindowAccessor.Coordinator

extension WindowAccessor {
    final class Coordinator {
        weak var lastWindow: NSWindow?
    }
}

// MARK: - WindowObservingView

final class WindowObservingView: NSView {
    // MARK: Properties

    var onWindow: ((NSWindow) -> Void)?

    // MARK: Overridden Functions

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
