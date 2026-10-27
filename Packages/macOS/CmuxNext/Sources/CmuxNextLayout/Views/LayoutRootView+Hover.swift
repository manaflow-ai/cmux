public import AppKit
import CmuxNextDesign
import CmuxNextWakeups

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
    /// The notices come through the window's one fan-out (``WindowEvents``;
    /// Chromium observes an NSWindow once, in
    /// components/remote_cocoa/app_shim/views_nswindow_delegate.mm), in the
    /// notice's own turn, in ``MainWorkClass/input``: the click or Cmd-Tab
    /// that moves the keys is input, and the hover follows in the frame that
    /// input commits. Only a live root subscribes, so a hidden or parked one
    /// gets no call; `setLive` subscribes again on show.
    func observeKeyWindow() {
        for subscription in keyWindowObservers { subscription.cancel() }
        keyWindowObservers = []
        guard isLive, let window else { return }
        let events = context.hoverWindowEvents(window)
        keyWindowObservers = [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification].map { name in
            // input-hop-allow: class input; the key change is the click's or Cmd-Tab's own effect, and a later turn would commit that input's frame with the divider hover of the old key state.
            events.subscribe(name, owner: "LayoutRootView.dividerHover") { [weak self] in self?.refreshDividerHover() }
        }
    }

    #if DEBUG || CMUX_BENCH_HOOKS
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
