/// An IME composition underline (UTF-16 offsets into the composition text).
public struct RbUnderline: Hashable, Sendable {
    public var start: UInt32
    public var end: UInt32
    public var thick: Bool

    public init(start: UInt32, end: UInt32, thick: Bool = false) {
        self.start = start
        self.end = end
        self.thick = thick
    }
}
