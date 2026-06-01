import Foundation

@_spi(CmuxHostTransport)
public struct CmuxSidebarActionResult: Codable, Equatable, Sendable {
    public var accepted: Bool
    public var message: String?

    public init(accepted: Bool, message: String? = nil) {
        self.accepted = accepted
        self.message = message
    }

    public static let accepted = CmuxSidebarActionResult(accepted: true)

    public static func rejected(_ message: String) -> CmuxSidebarActionResult {
        CmuxSidebarActionResult(accepted: false, message: message)
    }
}

public enum CmuxSidebarActionError: Error, Equatable, Sendable {
    case rejected(String)
    case cancelled
}
