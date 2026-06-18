/// A read-only snapshot of one connected display, as the app target exposes it
/// to ``ControlCommandCoordinator`` through ``ControlCommandContext``.
///
/// Mirrors the app target's `AppDelegate.DisplayInfo` without the package
/// importing AppKit: the frame is carried as four scalars (the coordinator
/// truncates them to `Int` for the `window.displays` payload, matching the
/// legacy `Int(frame.origin.x)` conversion).
public struct ControlDisplayInfo: Sendable, Equatable {
    /// The display's localized name.
    public let name: String
    /// The display's zero-based index in screen order.
    public let index: Int
    /// The Core Graphics display id, if available.
    public let displayID: UInt32?
    /// Whether this is the main display.
    public let isMain: Bool
    /// The display frame's minimum-x origin, in points.
    public let frameX: Double
    /// The display frame's minimum-y origin, in points.
    public let frameY: Double
    /// The display frame width, in points.
    public let frameWidth: Double
    /// The display frame height, in points.
    public let frameHeight: Double

    /// Creates a display snapshot.
    ///
    /// - Parameters:
    ///   - name: The display's localized name.
    ///   - index: The zero-based screen-order index.
    ///   - displayID: The Core Graphics display id, if available.
    ///   - isMain: Whether this is the main display.
    ///   - frameX: The frame origin x, in points.
    ///   - frameY: The frame origin y, in points.
    ///   - frameWidth: The frame width, in points.
    ///   - frameHeight: The frame height, in points.
    public init(
        name: String,
        index: Int,
        displayID: UInt32?,
        isMain: Bool,
        frameX: Double,
        frameY: Double,
        frameWidth: Double,
        frameHeight: Double
    ) {
        self.name = name
        self.index = index
        self.displayID = displayID
        self.isMain = isMain
        self.frameX = frameX
        self.frameY = frameY
        self.frameWidth = frameWidth
        self.frameHeight = frameHeight
    }
}
