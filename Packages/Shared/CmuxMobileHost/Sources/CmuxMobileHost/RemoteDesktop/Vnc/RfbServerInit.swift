/// The server's ServerInit (RFC 6143 7.3.2), pixel format aside: this
/// client always sets its own (32-bit BGRA little-endian true colour).
public struct RfbServerInit: Hashable, Sendable {
    public var width: Int
    public var height: Int
    public var name: String

    public init(width: Int, height: Int, name: String) {
        self.width = width
        self.height = height
        self.name = name
    }
}
