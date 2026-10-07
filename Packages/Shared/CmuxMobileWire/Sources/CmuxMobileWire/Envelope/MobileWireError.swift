/// A decode failure with a cmux.mobile/1 error code (a0-rpc.md section 2).
public struct MobileWireError: Error, Hashable, Sendable {
    /// Dotted code, for example `proto.unknown_frame` or `validation.invalid`.
    public var code: String
    public var message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}
