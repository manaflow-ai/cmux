import AppKit
import SwiftUI

@MainActor
struct WindowAccessor: NSViewRepresentable {
    let onWindow: @MainActor (NSWindow) -> Void
    let dedupeByWindow: Bool

    init(dedupeByWindow: Bool = true, onWindow: @escaping @MainActor (NSWindow) -> Void) {
        self.onWindow = onWindow
        self.dedupeByWindow = dedupeByWindow
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WindowObservingView {
        let view = WindowObservingView()
        installWindowHandler(
            on: view,
            coordinator: context.coordinator
        )
        return view
    }

    func updateNSView(_ nsView: WindowObservingView, context: Context) {
        installWindowHandler(
            on: nsView,
            coordinator: context.coordinator
        )
        if let window = nsView.window {
            nsView.onWindow?(window)
        }
    }

    private func installWindowHandler(
        on view: WindowObservingView,
        coordinator: Coordinator
    ) {
        let handler = onWindow
        let shouldDedupeByWindow = dedupeByWindow
        view.onWindow = { window in
            guard !shouldDedupeByWindow || coordinator.lastWindow !== window else { return }
            coordinator.lastWindow = window
            handler(window)
        }
    }
}

extension WindowAccessor {
    final class Coordinator {
        weak var lastWindow: NSWindow?
    }
}

@MainActor
final class WindowObservingView: NSView {
    var onWindow: (@MainActor (NSWindow) -> Void)?

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
