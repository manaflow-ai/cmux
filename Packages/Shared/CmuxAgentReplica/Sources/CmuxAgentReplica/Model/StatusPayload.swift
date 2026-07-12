import Foundation

/// Carries a transcript status entry.
public struct StatusPayload: Codable, Hashable, Sendable {
    /// The machine-readable status code.
    public let code: StatusCode
    /// Human-readable status detail, when available.
    public let detail: String?

    /// Creates a status payload.
    /// - Parameters:
    ///   - code: The machine-readable status code.
    ///   - detail: Human-readable status detail, when available.
    public init(code: StatusCode, detail: String? = nil) {
        self.code = code
        self.detail = detail
    }
}
