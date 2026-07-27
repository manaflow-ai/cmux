/// Stable identity shared by every AppKit entrypoint for one physical key event.
public struct PhysicalKeyEventIdentity: Sendable, Equatable {
    /// Exact bit pattern of the native event timestamp.
    public let timestampBitPattern: UInt64

    /// AppKit window that received the event.
    public let windowNumber: Int

    /// Opaque native-event identity used when synthetic events have timestamp zero.
    public let zeroTimestampEventToken: UInt

    /// Creates an identity from platform-neutral native-event fields.
    public init(
        timestampBitPattern: UInt64,
        windowNumber: Int,
        zeroTimestampEventToken: UInt = 0
    ) {
        self.timestampBitPattern = timestampBitPattern
        self.windowNumber = windowNumber
        self.zeroTimestampEventToken =
            Double(bitPattern: timestampBitPattern).isZero
            ? zeroTimestampEventToken
            : 0
    }
}

/// Compatibility name for the shortcut-routing lifecycle.
public typealias ShortcutKeyEventIdentity = PhysicalKeyEventIdentity
