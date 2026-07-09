internal import Foundation

/// The validated parameters of a `feedback.submit` control command.
///
/// `feedback.submit` requires a string `email` and string `body`, with an
/// optional `image_paths` array of strings. The legacy `TerminalController`
/// validated these inline before handing them to the feedback composer; this
/// value type owns that parameter validation so the parse is a single,
/// testable unit and the worker-lane body only performs the app-coupled
/// submission.
///
/// The extraction mirrors the legacy reads exactly: `email`/`body` use
/// `as? String` (a missing or non-string value is a parse failure naming the
/// field), and `image_paths` uses `as? [String] ?? []` (a missing or
/// wrong-typed array yields an empty list rather than failing).
public struct FeedbackSubmissionRequest: Sendable, Equatable {
    /// The submitter email address (`params["email"]`).
    public let email: String
    /// The feedback message body (`params["body"]`).
    public let body: String
    /// The optional attachment image paths (`params["image_paths"]`), empty when
    /// absent or not a `[String]`.
    public let imagePaths: [String]

    /// The reason a `feedback.submit` parameter validation failed, naming the
    /// offending field so the caller can build the legacy
    /// `data: ["field": …]` error payload.
    public enum ParseError: Sendable, Equatable {
        /// `email` was missing or not a string.
        case missingEmail
        /// `body` was missing or not a string.
        case missingBody

        /// The `field` value the legacy error payload reported for this failure.
        public var field: String {
            switch self {
            case .missingEmail: return "email"
            case .missingBody: return "body"
            }
        }

        /// The human-readable message the legacy error reported for this failure.
        public var message: String {
            switch self {
            case .missingEmail: return "Missing email"
            case .missingBody: return "Missing body"
            }
        }
    }

    /// Validates the raw `feedback.submit` params exactly as the legacy body did.
    ///
    /// - Parameter params: The decoded command params.
    /// - Throws: ``ParseError`` when `email` or `body` is missing or non-string.
    public init(params: [String: Any]) throws {
        guard let email = params["email"] as? String else {
            throw ParseError.missingEmail
        }
        guard let body = params["body"] as? String else {
            throw ParseError.missingBody
        }
        self.email = email
        self.body = body
        self.imagePaths = params["image_paths"] as? [String] ?? []
    }
}

extension FeedbackSubmissionRequest.ParseError: Error {}
