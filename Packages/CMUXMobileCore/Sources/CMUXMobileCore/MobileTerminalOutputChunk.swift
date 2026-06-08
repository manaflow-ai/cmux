import Foundation

/// One chunk yielded by the phone's terminal output stream.
///
/// Bytes and the authoritative grid that produced them travel together so the
/// surface can pin its geometry from the *same* frame whose VT bytes it
/// applies, keeping content and grid atomic. ``grid`` is `nil` only for the
/// raw-byte compatibility fallback (an older Mac host with no render-grid
/// frame), which carries no authoritative grid; such a chunk leaves the pin
/// untouched.
public struct MobileTerminalOutputChunk: Equatable, Sendable {
    /// The VT bytes to feed to the local libghostty surface.
    public var bytes: Data
    /// The authoritative Mac grid carried by the frame these bytes came from,
    /// or `nil` for a raw-byte fallback chunk with no grid.
    public var grid: MobileTerminalGridPin?

    /// Creates an output chunk.
    /// - Parameters:
    ///   - bytes: The VT bytes to feed to the local libghostty surface.
    ///   - grid: The authoritative grid carried by the producing frame, or
    ///     `nil` for a raw-byte fallback chunk.
    public init(bytes: Data, grid: MobileTerminalGridPin? = nil) {
        self.bytes = bytes
        self.grid = grid
    }
}
