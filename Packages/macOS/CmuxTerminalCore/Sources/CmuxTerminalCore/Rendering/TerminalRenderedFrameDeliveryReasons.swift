/// Surface-scoped work requested when Ghostty vends a rendered frame.
///
/// The renderer keeps cursor-only updates separate from the shared
/// notification bus so a keyboard-copy overlay does not wake unrelated
/// observers.
public struct TerminalRenderedFrameDeliveryReasons: OptionSet, Sendable {
    /// Raw option bits.
    public let rawValue: UInt8

    /// Creates a reason set from raw option bits.
    ///
    /// - Parameter rawValue: Bitwise combination of known reasons.
    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    /// Publish the surface's shared rendered-frame notification.
    public static let notification = Self(rawValue: 1 << 0)

    /// Refresh only the surface's keyboard-copy cursor overlay.
    public static let keyboardCopyModeCursor = Self(rawValue: 1 << 1)
}
