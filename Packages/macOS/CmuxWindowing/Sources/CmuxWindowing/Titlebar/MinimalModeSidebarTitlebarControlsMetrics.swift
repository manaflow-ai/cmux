public import AppKit

/// Geometry for the minimal-mode sidebar titlebar control region: where the
/// host sits, how wide and tall it is, and the exact frame it occupies in a
/// window's content coordinates.
///
/// A pure value type. The leading and top insets are resolved once from
/// `UserDefaults` (via ``MinimalModeTitlebarDebugSnapshot``) at init and stored;
/// the intrinsic host dimensions are compile-time constants. The app target
/// builds an instance from the live `UserDefaults` and asks it for the control
/// frame, so the geometry math has no live window coupling of its own. The one
/// window-aware helper (``titlebarControlsOpticalYOffset(in:)``) is a thin
/// `@MainActor` read of the backing scale factor.
public struct MinimalModeSidebarTitlebarControlsMetrics {
    /// The leading inset of the control host, resolved from defaults.
    public let leadingInset: CGFloat
    /// The top inset of the control host, resolved from defaults.
    public let topInset: CGFloat

    /// Resolves the leading and top insets from `defaults`.
    public init(defaults: UserDefaults = .standard) {
        self.leadingInset = MinimalModeTitlebarDebugSnapshot.leftControlsLeadingInset(defaults: defaults)
        self.topInset = MinimalModeTitlebarDebugSnapshot.leftControlsTopInset(defaults: defaults)
    }

    /// The width of the multi-button control host.
    public static let hostWidth: CGFloat = 164
    /// The height of the control host.
    public static let hostHeight: CGFloat = 28
    /// The width of a single-button control host (a square of ``hostHeight``).
    public static let singleButtonHostWidth: CGFloat = hostHeight

    /// The vertical optical adjustment for the control host. Currently zero
    /// regardless of backing scale; kept as a seam for scale-aware tuning.
    public static func titlebarControlsOpticalYOffset(backingScaleFactor _: CGFloat?) -> CGFloat {
        0
    }

    /// The vertical optical adjustment resolved from a window's backing scale
    /// (falling back to the main screen's scale when the window is absent).
    @MainActor
    public static func titlebarControlsOpticalYOffset(in window: NSWindow?) -> CGFloat {
        titlebarControlsOpticalYOffset(
            backingScaleFactor: window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor
        )
    }

    /// Computes the control host's frame within content coordinates.
    ///
    /// When `trafficLightFrameInContent` is present the host is vertically
    /// centered on the traffic lights (offset by `visualDownwardAdjustment` in
    /// the appropriate direction for the content view's flipped-ness);
    /// otherwise it is pinned to the top inset. The horizontal origin is always
    /// ``leadingInset`` and the size is ``hostWidth`` by ``hostHeight``.
    public func controlsFrame(
        contentBounds: NSRect,
        contentViewIsFlipped: Bool,
        trafficLightFrameInContent: NSRect?,
        visualDownwardAdjustment: CGFloat = 0
    ) -> NSRect {
        let hostHeight = Self.hostHeight
        let targetY: CGFloat
        if let trafficLightFrameInContent {
            let centeredY = trafficLightFrameInContent.midY - hostHeight / 2.0
            targetY = contentViewIsFlipped
                ? centeredY + visualDownwardAdjustment
                : centeredY - visualDownwardAdjustment
        } else {
            targetY = contentViewIsFlipped
                ? contentBounds.minY + topInset
                : max(0, contentBounds.maxY - hostHeight - topInset)
        }
        return NSRect(
            x: leadingInset,
            y: targetY,
            width: Self.hostWidth,
            height: hostHeight
        )
    }
}
