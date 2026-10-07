/// A signaling session id, `sess_` plus 22 base62 characters (about 131
/// bits), matching the relay's `sess_[A-Za-z0-9]{2,64}`.
public struct SignalSessionID: Sendable, Hashable, CustomStringConvertible {
    public let rawValue: String

    public init() {
        let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
        var generator = SystemRandomNumberGenerator()
        let body = (0..<22).map { _ in alphabet[Int(generator.next(upperBound: UInt64(alphabet.count)))] }
        rawValue = "sess_" + String(body)
    }

    public var description: String { rawValue }
}
