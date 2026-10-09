/// Why a device was not admitted, in the shared error shape.
public struct MobileAuthFailure: Error, Hashable, Sendable {
    /// `auth.unauthenticated` (no or bad proof) or `auth.forbidden` (not paired, revoked, other account).
    public var code: String
    public var message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    public static func unauthenticated(_ message: String) -> MobileAuthFailure {
        MobileAuthFailure(code: "auth.unauthenticated", message: message)
    }

    public static func forbidden(_ message: String) -> MobileAuthFailure {
        MobileAuthFailure(code: "auth.forbidden", message: message)
    }
}
