import AppKit
import SwiftUI

@MainActor
struct WindowAccessor: NSViewRepresentable {
    let onWindow: @MainActor (NSWindow) -> Void
    let dedupeByWindow: Bool
    let refreshID: AnyHashable?

    init(
        dedupeByWindow: Bool = true,
        refreshID: AnyHashable? = nil,
        onWindow: @escaping @MainActor (NSWindow) -> Void
    ) {
        self.onWindow = onWindow
        self.dedupeByWindow = dedupeByWindow
        self.refreshID = refreshID
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
        let refreshID = refreshID
        view.onWindow = { window in
            guard coordinator.shouldInvoke(
                window: window,
                dedupeByWindow: shouldDedupeByWindow,
                refreshID: refreshID
            ) else { return }
            handler(window)
        }
    }
}

extension WindowAccessor {
    final class Coordinator {
        private weak var lastWindow: NSWindow?
        private var lastRefreshID: AnyHashable?

        func shouldInvoke(
            window: NSWindow,
            dedupeByWindow: Bool,
            refreshID: AnyHashable?
        ) -> Bool {
            if dedupeByWindow, lastWindow === window, lastRefreshID == refreshID {
                return false
            }

            lastWindow = window
            lastRefreshID = refreshID
            return true
        }
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
