/// A `cmux.rd/1` or `cmux.rb/1` value that does not decode.
public struct RdWireError: Error, Hashable, Sendable, CustomStringConvertible {
    public var message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
}
