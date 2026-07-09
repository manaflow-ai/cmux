public import CoreGraphics

/// Decides where a new main window opens relative to the window it was created
/// from, cascading it down-right by a fixed offset.
///
/// This is the pure-geometry policy lifted out of
/// `AppDelegate.positionNewMainWindow(_:relativeTo:)`: given the source
/// window's frame, whether its screen's visible area is resolvable, and the new
/// window's current size, it produces a ``NewWindowCascadePlacement``. The app
/// target keeps the AppKit edges (reading `NSScreen.visibleFrame`, calling
/// `window.setFrame`/`window.center()`, and the final clamp onto the visible
/// area via `SessionWindowFrameResolver.clampFrame`), so the on-screen behavior
/// and the clamp's single source of truth are unchanged.
///
/// A pure value type holding only its injected constants, so it is `Sendable`
/// and tested without AppKit, mirroring ``SessionDisplayGeometry``-style value
/// math in this package. It is constructed (not a static namespace) so the
/// cascade offset and minimum-size floor are injectable.
public struct NewWindowCascadePlanner: Sendable {
    /// How far down and right the new window cascades from the source window's
    /// top-left, in points.
    public let cascadeOffset: CGFloat

    /// The minimum content size the app applies when clamping the cascaded
    /// frame onto the source screen's visible area. Exposed so the app target
    /// passes the same floor into `SessionWindowFrameResolver.clampFrame`.
    public let minimumWindowSize: CGSize

    /// Creates a planner with the cascade offset and minimum-size floor used by
    /// new main windows.
    ///
    /// - Parameters:
    ///   - cascadeOffset: Points to shift the new window down and right from the
    ///     source window (the app passes `24`).
    ///   - minimumWindowSize: The clamp floor for the cascaded frame (the app
    ///     passes `460 x 360`).
    public init(
        cascadeOffset: CGFloat = 24,
        minimumWindowSize: CGSize = CGSize(width: 460, height: 360)
    ) {
        self.cascadeOffset = cascadeOffset
        self.minimumWindowSize = minimumWindowSize
    }

    /// Plans the placement of a new window relative to its source window.
    ///
    /// When `hasResolvableScreen` is `false` the source screen's visible frame
    /// could not be resolved, so the window centers. Otherwise the new window's
    /// origin is cascaded from the source frame's top-left (down-right by
    /// ``cascadeOffset``, keeping its current `windowSize`); the returned frame
    /// is the pre-clamp candidate, which the app clamps onto the visible area
    /// with ``minimumWindowSize`` as the floor.
    ///
    /// - Parameters:
    ///   - sourceFrame: The source window's frame in global screen coordinates.
    ///   - hasResolvableScreen: Whether the source screen's visible frame is
    ///     available (the app resolves it from `NSScreen`).
    ///   - windowSize: The new window's current frame size, preserved by the
    ///     cascade.
    /// - Returns: ``NewWindowCascadePlacement/center`` or
    ///   ``NewWindowCascadePlacement/frame(_:)`` with the unclamped candidate.
    public func placement(
        sourceFrame: CGRect,
        hasResolvableScreen: Bool,
        windowSize: CGSize
    ) -> NewWindowCascadePlacement {
        guard hasResolvableScreen else { return .center }
        let origin = CGPoint(
            x: sourceFrame.minX + cascadeOffset,
            y: sourceFrame.maxY - cascadeOffset - windowSize.height
        )
        return .frame(CGRect(origin: origin, size: windowSize))
    }
}
