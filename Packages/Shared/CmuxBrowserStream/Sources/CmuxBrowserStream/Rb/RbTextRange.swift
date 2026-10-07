/// A UTF-16 range `[start, end)` in the focused field (IME replacement range).
public struct RbTextRange: Hashable, Sendable {
    public var start: UInt32
    public var end: UInt32

    public init(start: UInt32, end: UInt32) {
        self.start = start
        self.end = max(start, end)
    }
}
