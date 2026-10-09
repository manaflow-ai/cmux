public import AppKit
import CmuxNextDesign

/// Divider hover (cx-ww20): each screen view owns the hover of its
/// handles and recomputes it from the pointer and the current frames. The
/// root adds the window-level inputs: key-window changes and the app's
/// pass-through panels.
extension LayoutRootView {
    /// Windows above this one that pass divider hover through (the app's
    /// click-catching panels over page windows).
    public var hoverPassThroughWindows: () -> Set<Int> {
        get { context.hoverPassThroughWindows }
        set { context.hoverPassThroughWindows = newValue }
    }

    /// Recomputes divider hover now, after something outside the layout
    /// moved what lies under the pointer (the catcher panels moved, a panel
    /// above closed).
    public func refreshDividerHover() {
        for view in screenViews.values where !view.isHidden { view.refreshDividerHover() }
    }

    /// Becoming or resigning key changes whether the pointer may hover at
    /// all: a resigned window clears its hover without a mouse event.
    func observeKeyWindow() {
        let center = NotificationCenter.default
        for observer in keyWindowObservers { center.removeObserver(observer) }
        keyWindowObservers.removeAll()
        guard let window else { return }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            keyWindowObservers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] notification in
                // main-proof: NotificationCenter delivers this block on the main operation queue.
                MainActor.assumeIsolated { self?.keyWindowChanged(notification) }
            })
        }
    }

    private func keyWindowChanged(_ notification: Notification) {
        refreshDividerHover()
    }

    #if DEBUG
    /// DEBUG (`debug.mouse`): the synthesized pointer of `window` (window
    /// coordinates; nil: outside the window), shared with every chrome hover
    /// (`PointerHover`, which recomputes them), then every layout in the
    /// window recomputes its divider hover from it.
    public static func setDebugPointer(_ point: NSPoint?, in window: NSWindow) {
        PointerHover.setDebugPointer(point, in: window)
        var stack: [NSView] = window.contentView.map { [$0] } ?? []
        while let view = stack.popLast() {
            if let root = view as? LayoutRootView { root.refreshDividerHover() } else { stack.append(contentsOf: view.subviews) }
        }
    }
    #endif
}
