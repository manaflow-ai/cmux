import Foundation

@_spi(CmuxHostTransport)
/// Result returned by CMUX for a sidebar host action request.
public struct CmuxSidebarActionResult: Codable, Equatable, Sendable {
    /// Whether CMUX accepted and applied the action.
    public var accepted: Bool

    /// Optional host-supplied result or rejection message.
    public var message: String?

    /// Structured reason when the action was rejected.
    public var rejectionReason: CmuxSidebarActionRejectionReason?

    /// Creates an action result.
    public init(
        accepted: Bool,
        message: String? = nil,
        rejectionReason: CmuxSidebarActionRejectionReason? = nil
    ) {
        self.accepted = accepted
        self.message = message
        self.rejectionReason = accepted ? nil : rejectionReason
    }

    /// Successful action result.
    public static let accepted = CmuxSidebarActionResult(accepted: true)

    /// Creates a rejected action result with a displayable message.
    public static func rejected(
        _ message: String,
        reason: CmuxSidebarActionRejectionReason = .rejected
    ) -> CmuxSidebarActionResult {
        CmuxSidebarActionResult(accepted: false, message: message, rejectionReason: reason)
    }

    /// Rejected action result used when the caller cancels an in-flight request.
    public static let cancelled = CmuxSidebarActionResult(
        accepted: false,
        message: "Extension action was cancelled",
        rejectionReason: .cancelled
    )
}

@_spi(CmuxHostTransport)
/// Machine-readable reason CMUX rejected a sidebar action.
public enum CmuxSidebarActionRejectionReason: String, Codable, Equatable, Sendable {
    /// Generic host rejection.
    case rejected

    /// The caller cancelled the action before the host completed it.
    case cancelled
}

/// Error thrown by typed `CmuxSidebarHost` action helpers.
public enum CmuxSidebarActionError: Error, Equatable, Sendable {
    /// CMUX rejected the action with a displayable message.
    case rejected(String)

    /// The caller cancelled the action before completion.
    case cancelled
}
