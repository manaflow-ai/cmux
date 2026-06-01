import Foundation

@_spi(CmuxHostTransport)
public struct CmuxSidebarActionResult: Codable, Equatable, Sendable {
    public var accepted: Bool
    public var message: String?
    public var rejectionReason: CmuxSidebarActionRejectionReason?

    public init(
        accepted: Bool,
        message: String? = nil,
        rejectionReason: CmuxSidebarActionRejectionReason? = nil
    ) {
        self.accepted = accepted
        self.message = message
        self.rejectionReason = accepted ? nil : rejectionReason
    }

    public static let accepted = CmuxSidebarActionResult(accepted: true)

    public static func rejected(
        _ message: String,
        reason: CmuxSidebarActionRejectionReason = .rejected
    ) -> CmuxSidebarActionResult {
        CmuxSidebarActionResult(accepted: false, message: message, rejectionReason: reason)
    }

    public static let cancelled = CmuxSidebarActionResult(
        accepted: false,
        message: "Extension action was cancelled",
        rejectionReason: .cancelled
    )
}

@_spi(CmuxHostTransport)
public enum CmuxSidebarActionRejectionReason: String, Codable, Equatable, Sendable {
    case rejected
    case cancelled
}

public enum CmuxSidebarActionError: Error, Equatable, Sendable {
    case rejected(String)
    case cancelled
}
