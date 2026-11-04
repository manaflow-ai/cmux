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
    /// above closed): the window server is asked again what is on top there.
    public func refreshDividerHover() {
        context.invalidateHoverTopmost()
        for view in screenViews.values where !view.isHidden { view.refreshDividerHover() }
    }

    /// Becoming or resigning key changes whether the pointer may hover at
    /// all: a resigned window clears its hover without a mouse event.
    /// Block observers on `queue: .main` (inline for AppKit's post on main):
    /// a selector into this main-actor view trapped on a post off main.
    func observeKeyWindow() {
        let center = NotificationCenter.default
        for token in keyWindowObservers { center.removeObserver(token) }
        keyWindowObservers = []
        guard isLive, let window else { return }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            keyWindowObservers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshDividerHover() } // main-proof: observer on queue: .main
            })
        }
    }

    #if DEBUG || CMUX_BENCH_HOOKS
    /// DEBUG (`debug.cursor`, control build): the cursor shown, the hover pointer, the topmost window and hover.
    public static func debugCursorReport() -> [String: String] {
        var report = ["app": NSCursor.current.debugName, "system": NSCursor.currentSystem?.debugName ?? "none"]
        guard let window = NSApp.keyWindow else { return report.merging(["key_window": "none"]) { $1 } }
        var stack: [NSView] = window.contentView.map { [$0] } ?? []
        while let view = stack.popLast() {
            guard let root = view as? LayoutRootView else { stack.append(contentsOf: view.subviews); continue }
            report["pointer"] = root.context.hoverPointer(window).map { "\($0.x),\($0.y)" } ?? "none"
            let top = NSWindow.windowNumber(at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0)
            let owner = NSApp.windows.first { $0.windowNumber == top }
            report["topmost"] = "\(top) key=\(window.windowNumber) ours=\(owner.map { String(describing: type(of: $0)) } ?? "no")"
            for (id, screen) in root.screenViews where !screen.isHidden {
                let hovered = screen.dividerViews.values.filter(\.isHovered).map(\.kind.mouseAreaID).sorted()
                report["screen.\(id.rawValue)"] = "hovered=\(hovered.joined(separator: "+"))"
            }
        }
        return report
    }

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
