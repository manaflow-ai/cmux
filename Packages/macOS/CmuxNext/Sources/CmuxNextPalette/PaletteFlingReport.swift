#if DEBUG
/// What one fling of the open palette's list cost (``PaletteController/debugFling(seconds:pointsPerFrame:pointerFraction:)``,
/// the `debug.palette.fling` socket verb; perf-lead row 23 test plan step 5).
///
/// The list scrolls a fixed distance on every display refresh under a pointer that rests over it,
/// the way a fling moves rows under a still mouse, so the row under the pointer changes about once
/// per row of travel and hover must follow it on the next frame.
public struct PaletteFlingReport: Sendable, Equatable {
    /// The intervals between the display link's frames on the main thread, in milliseconds. A
    /// frame the main thread was too busy to take shows as one interval of two or more refreshes.
    public var intervalsMs: [Double]
    /// One display refresh in milliseconds (8.3 at 120 Hz).
    public var refreshMs: Double
    /// The main thread's synchronous work per frame (the scroll, its hit test and hover), in
    /// milliseconds; the hover hop that follows is not in it.
    public var workMs: [Double]
    /// How far the list moved, in points, over every frame.
    public var scrolledPoints: Double
    /// Frames on which the hovered row had changed since the frame before.
    public var hoverChanges: Int
    /// Frames on which the hovered row was not the row under the pointer: hover one frame or more
    /// behind the scroll.
    public var hoverMisses: Int
    /// Whole-palette renders the fling caused (search bar, footer, menus, layout); 0 when hover
    /// touches only the rows it moves between.
    public var paletteRenders: Int

    /// Intervals longer than 1.5 refreshes: each one at least one refresh the list did not move.
    public var longFrames: Int { intervalsMs.filter { $0 > 1.5 * refreshMs }.count }
}
#endif
