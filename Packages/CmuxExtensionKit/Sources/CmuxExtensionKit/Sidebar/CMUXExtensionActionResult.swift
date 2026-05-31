import Foundation

public struct CMUXExtensionActionResult: Codable, Equatable, Sendable {
    public var accepted: Bool
    public var message: String?

    public init(accepted: Bool, message: String? = nil) {
        self.accepted = accepted
        self.message = message
    }

    public static let accepted = CMUXExtensionActionResult(accepted: true)

    public static func rejected(_ message: String) -> CMUXExtensionActionResult {
        CMUXExtensionActionResult(accepted: false, message: message)
    }
}
