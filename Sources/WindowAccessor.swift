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
        // Not nsView.window: SwiftUI can update this view while its window is
        // deallocating. Resolve the identity captured by AppKit's move callback
        // against the live application windows instead of touching a weak
        // reference during teardown.
        if let window = nsView.liveWindow {
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
        view.onWindowDetached = {
            coordinator.reset()
        }
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
        private var lastWindowIdentifier: ObjectIdentifier?
        private var lastRefreshID: AnyHashable?

        func reset() {
            lastWindowIdentifier = nil
            lastRefreshID = nil
        }

        func shouldInvoke(
            window: NSWindow,
            dedupeByWindow: Bool,
            refreshID: AnyHashable?
        ) -> Bool {
            let windowIdentifier = ObjectIdentifier(window)
            if dedupeByWindow, lastWindowIdentifier == windowIdentifier, lastRefreshID == refreshID {
                return false
            }

            lastWindowIdentifier = windowIdentifier
            lastRefreshID = refreshID
            return true
        }
    }
}

@MainActor
final class WindowObservingView: NSView {
    var onWindow: (@MainActor (NSWindow) -> Void)?
    var onWindowDetached: (@MainActor () -> Void)?
    /// Set only from AppKit's move callback, where the window identity is live.
    /// Keeping the identity avoids forming a weak reference while AppKit is
    /// tearing down an NSKVONotifying window.
    private(set) var trackedWindowIdentifier: ObjectIdentifier?

    @MainActor
    var liveWindow: NSWindow? {
        guard let trackedWindowIdentifier else { return nil }
        return NSApp.windows.first { ObjectIdentifier($0) == trackedWindowIdentifier }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            trackedWindowIdentifier = nil
            onWindowDetached?()
        } else if let newWindow {
            onWindow?(newWindow)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        trackedWindowIdentifier = window.map { ObjectIdentifier($0) }
        if let window {
            onWindow?(window)
        } else {
            onWindowDetached?()
        }
    }
}
