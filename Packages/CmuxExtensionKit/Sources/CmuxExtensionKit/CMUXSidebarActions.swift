import Foundation

public enum CMUXSidebarAction: Codable, Equatable, Sendable {
    case selectWorkspace(UUID)
    case closeWorkspace(UUID)
    case openURL(String)
}

public struct CMUXExtensionActionResult: Codable, Equatable, Sendable {
    public var accepted: Bool
    public var message: String?

    public init(accepted: Bool, message: String? = nil) {
        self.accepted = accepted
        self.message = message
    }

    public static let accepted = CMUXExtensionActionResult(accepted: true)
}
