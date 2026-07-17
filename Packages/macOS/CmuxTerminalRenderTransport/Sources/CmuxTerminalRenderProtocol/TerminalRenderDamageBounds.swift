/// A non-empty pixel-space bounding rectangle for frame damage.
public struct TerminalRenderDamageBounds: Equatable, Sendable {
    /// Horizontal pixel origin.
    public let x: UInt32

    /// Vertical pixel origin.
    public let y: UInt32

    /// Damaged pixel width.
    public let width: UInt32

    /// Damaged pixel height.
    public let height: UInt32

    /// Creates damage bounds with nonzero width and height.
    ///
    /// - Parameters:
    ///   - x: Horizontal pixel origin.
    ///   - y: Vertical pixel origin.
    ///   - width: Nonzero damaged width.
    ///   - height: Nonzero damaged height.
    /// - Throws: ``TerminalRenderFrameProtocolError/invalidDamageBounds`` for an empty rectangle.
    public init(x: UInt32, y: UInt32, width: UInt32, height: UInt32) throws {
        guard width > 0, height > 0 else {
            throw TerminalRenderFrameProtocolError.invalidDamageBounds
        }
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// Returns whether the rectangle fits completely inside a frame.
    ///
    /// - Parameters:
    ///   - frameWidth: Frame width in pixels.
    ///   - frameHeight: Frame height in pixels.
    /// - Returns: `true` only when both rectangle edges are in bounds without overflow.
    public func isContained(frameWidth: UInt32, frameHeight: UInt32) -> Bool {
        let (maxX, xOverflowed) = x.addingReportingOverflow(width)
        let (maxY, yOverflowed) = y.addingReportingOverflow(height)
        return !xOverflowed && !yOverflowed && maxX <= frameWidth && maxY <= frameHeight
    }
}
