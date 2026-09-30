public import AppKit

/// A connected display, surfaced by the `window.displays` control command and
/// the `cmux window display --list` CLI so callers can discover screen names,
/// indices, and frames.
///
/// A pure `Sendable` value type built by the app target from `NSScreen` state;
/// it carries no live AppKit object reference.
public struct DisplayInfo: Sendable {
    /// Localized display name (e.g. "LG HDR 4K").
    public let name: String
    /// Zero-based index in `NSScreen.screens` order.
    public let index: Int
    /// CoreGraphics display id, when resolvable.
    public let displayID: UInt32?
    /// Whether this is the main display.
    public let isMain: Bool
    /// The display's frame in global screen coordinates.
    public let frame: NSRect

    /// Creates a display descriptor.
    public init(
        name: String,
        index: Int,
        displayID: UInt32?,
        isMain: Bool,
        frame: NSRect
    ) {
        self.name = name
        self.index = index
        self.displayID = displayID
        self.isMain = isMain
        self.frame = frame
    }
}
