import Foundation

/// The 16-byte VNC authentication response for a challenge (servers and test fixtures check a
/// client's answer with it): cmux-vnc's DES (``VNCRules/passwordResponse(password:challenge:)``).
public struct VNCPasswordResponse: Sendable, Equatable {
    public let bytes: [UInt8]

    /// Empty without rules.
    public init(password: String, challenge: [UInt8], rules: VNCRules) {
        bytes = rules.passwordResponse(password: password, challenge: challenge) ?? []
    }
}
