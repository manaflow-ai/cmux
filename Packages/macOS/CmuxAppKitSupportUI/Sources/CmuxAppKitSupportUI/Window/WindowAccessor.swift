public import AppKit
public import SwiftUI

/// A zero-size SwiftUI bridge that hands its enclosing `NSWindow` to a callback as
/// soon as the hosting view is attached to (or moved between) windows.
///
/// Place it in a `.background(...)` to reach the AppKit window backing a SwiftUI
/// scene. The callback fires on the main actor whenever the view's window changes.
/// `dedupeByWindow` suppresses repeat invocations for the same window unless
/// `refreshID` changes, so callers can re-run window mutations on a state change
/// without redundant work for an unchanged window.
@MainActor
public struct WindowAccessor: NSViewRepresentable {
    let onWindow: @MainActor (NSWindow) -> Void
    let dedupeByWindow: Bool
    let refreshID: AnyHashable?

    /// Creates a window accessor.
    /// - Parameters:
    ///   - dedupeByWindow: When `true` (default), `onWindow` is skipped for a
    ///     window already seen with the same `refreshID`.
    ///   - refreshID: An optional token that, when changed, re-permits `onWindow`
    ///     for an already-seen window.
    ///   - onWindow: The main-actor callback invoked with the enclosing window.
    public init(
        dedupeByWindow: Bool = true,
        refreshID: AnyHashable? = nil,
        onWindow: @escaping @MainActor (NSWindow) -> Void
    ) {
        self.onWindow = onWindow
        self.dedupeByWindow = dedupeByWindow
        self.refreshID = refreshID
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    public func makeNSView(context: Context) -> WindowObservingView {
        let view = WindowObservingView()
        installWindowHandler(
            on: view,
            coordinator: context.coordinator
        )
        return view
    }

    public func updateNSView(_ nsView: WindowObservingView, context: Context) {
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
    /// Tracks the last window/`refreshID` pair so `WindowAccessor` can dedupe
    /// repeat callbacks for an unchanged window.
    public final class Coordinator {
        private weak var lastWindow: NSWindow?
        private var lastRefreshID: AnyHashable?

        /// Creates an empty coordinator with no observed window yet.
        public init() {}

        /// Returns whether `onWindow` should fire for `window`, recording it as the
        /// most recently seen window/`refreshID` pair.
        public func shouldInvoke(
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

/// The `NSView` backing ``WindowAccessor`` that reports its enclosing window as it
/// is attached to or moved between windows.
@MainActor
public final class WindowObservingView: NSView {
    var onWindow: (@MainActor (NSWindow) -> Void)?

    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if let newWindow {
            onWindow?(newWindow)
        }
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            onWindow?(window)
        }
    }
}
