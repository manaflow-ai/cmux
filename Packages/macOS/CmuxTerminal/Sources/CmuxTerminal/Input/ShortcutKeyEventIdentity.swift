/// Stable identity shared by every AppKit entrypoint for one keyboard event.
public struct ShortcutKeyEventIdentity: Sendable, Equatable {
    /// Exact bit pattern of the native event timestamp.
    public let timestampBitPattern: UInt64

    /// AppKit window that received the event.
    public let windowNumber: Int

    /// Creates an identity from platform-neutral native-event fields.
    public init(timestampBitPattern: UInt64, windowNumber: Int) {
        self.timestampBitPattern = timestampBitPattern
        self.windowNumber = windowNumber
    }
}
