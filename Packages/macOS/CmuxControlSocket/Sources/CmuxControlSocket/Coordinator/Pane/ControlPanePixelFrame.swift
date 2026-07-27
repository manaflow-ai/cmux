/// A pixel rectangle a pane occupies, as the app target exposes it to
/// ``ControlCommandCoordinator`` for the `pane.list` payload.
///
/// Mirrors Bonsplit's `PixelRect` without the package importing Bonsplit. The
/// coordinator emits each field as a JSON number, byte-faithful to the legacy
/// `pixel_frame` dictionary (`Double` values).
public struct ControlPanePixelFrame: Sendable, Equatable {
    /// The frame's origin x, in pixels.
    public let x: Double
    /// The frame's origin y, in pixels.
    public let y: Double
    /// The frame's width, in pixels.
    public let width: Double
    /// The frame's height, in pixels.
    public let height: Double

    /// Creates a pixel frame.
    ///
    /// - Parameters:
    ///   - x: The origin x, in pixels.
    ///   - y: The origin y, in pixels.
    ///   - width: The width, in pixels.
    ///   - height: The height, in pixels.
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}
