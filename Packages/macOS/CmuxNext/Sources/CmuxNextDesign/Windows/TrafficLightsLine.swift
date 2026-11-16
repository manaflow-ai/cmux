public import AppKit

/// The traffic lights on the top row's line (Austin 2026-11-10: "We need to make sure that the traffic
/// lights are aligned to the densities as well (will need to adjust them as well according to which
/// density the user selects)").
///
/// macOS centers the lights in its titlebar, 16 pt below the window's top at every density. The
/// concentric top row (``TopRowLineLook/concentric``, the default) centers the tab pills, the toolbar
/// band and the sidebar's + on the pills' line, which moves down as the density grows (20 pt at
/// Compact, 21.5 pt at Default). The lights move onto that line, so the whole top row shares it. With
/// no such line (a standard titlebar, tab bars at the bottom, and the `lights` and `off` variants,
/// whose line is the lights' own) they go back to macOS's place. Either way the close button sits as far
/// from the window's left edge as from its top (Lawrence 2026-11-10: "make sure top land left are even"),
/// the way macOS places it in its own titlebar (9 pt and 9 pt), so the lights keep the corner's proportion.
@MainActor
public struct TrafficLightsLine {
    public init() {}

    /// Where the lights' container is and where the buttons sit in it.
    public nonisolated struct Placement: Equatable, Sendable {
        /// The container's height, from the window's top edge.
        public var containerHeight: CGFloat
        /// The buttons' center, from the window's top edge.
        public var centerY: CGFloat
        /// The close button's left edge, from the window's left edge: its top edge's inset.
        public var leadingX: CGFloat
    }

    /// The placement for buttons `buttonHeight` tall centered `centerY` below the window's top, in a
    /// container macOS made `nativeHeight` tall at the window's top. The container grows when the line
    /// puts the buttons past its bottom, so they stay inside it and keep their clicks (a view outside
    /// its superview's frame gets no hits). A nil `centerY` is macOS's own place: centered in the
    /// native container. Pure, so `TrafficLightsLineTests` holds it with fixed numbers.
    public nonisolated static func placement(centerY: CGFloat?, buttonHeight: CGFloat, nativeHeight: CGFloat,
                                             scale: CGFloat) -> Placement {
        let s = max(scale, 1)
        let center = ((centerY ?? nativeHeight / 2) * s).rounded() / s
        let height = max(nativeHeight, ((center + buttonHeight / 2) * s).rounded(.up) / s)
        return Placement(containerHeight: height, centerY: center, leadingX: ((center - buttonHeight / 2) * s).rounded() / s)
    }

    /// The line the lights take in `window`: the top row's (``WindowTitlebar/topRowLine(in:look:)``) for the
    /// variants whose line does not come from the lights, nil (macOS's place) otherwise.
    public static func targetCenterY(in window: NSWindow, look: TopRowLineLook = TopRowLineLook.tunable.value) -> CGFloat? {
        guard look != .lights, look != .off else { return nil }
        return WindowTitlebar.topRowLine(in: window, look: look)?.centerY
    }

    /// Moves `window`'s traffic lights onto its top row's line (``targetCenterY(in:look:)``), or back to macOS's place.
    public static func apply(in window: NSWindow) { // perf-hot: 1ms motion-frame
        apply(in: window, centerY: targetCenterY(in: window))
    }

    /// Moves `window`'s traffic lights onto `centerY` (from the window's top), or back to macOS's place
    /// for nil. Runs in the root view's layout, before anything reads the lights' frame, so every
    /// layout pass (a resize, a density change, the end of full screen) puts them back if AppKit moved
    /// them. Sets a frame only when it changes. Nothing in full screen, where the lights live in the
    /// menu bar's window.
    public static func apply(in window: NSWindow, centerY: CGFloat?) { // perf-hot: 1ms motion-frame
        guard !window.styleMask.contains(.fullScreen),
              let close = window.standardWindowButton(.closeButton), close.window === window,
              let titlebar = close.superview, let container = titlebar.superview, let frameView = container.superview else { return }
        let native = window.frame.height - window.contentLayoutRect.maxY
        guard native > 0 else { return }
        let placement = placement(centerY: centerY, buttonHeight: close.frame.height, nativeHeight: native,
                                  scale: window.backingScaleFactor)
        let containerFrame = CGRect(x: container.frame.minX,
                                    y: frameView.isFlipped ? 0 : frameView.bounds.maxY - placement.containerHeight,
                                    width: container.frame.width, height: placement.containerHeight)
        if container.frame != containerFrame { container.frame = containerFrame }
        // The buttons' center and the close button's left edge in window coordinates (bottom-left origin), then
        // in the titlebar view's. All three move by the close button's shift, so macOS's spacing between them stays.
        let anchor = titlebar.convert(CGPoint(x: placement.leadingX, y: window.frame.height - placement.centerY), from: nil)
        let dx = window.windowTitlebarLayoutDirection == .leftToRight ? anchor.x - close.frame.minX : 0
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window.standardWindowButton(type), button.superview === titlebar else { continue }
            let origin = CGPoint(x: button.frame.minX + dx, y: anchor.y - button.frame.height / 2)
            if button.frame.origin != origin { button.setFrameOrigin(origin) }
        }
    }
}
