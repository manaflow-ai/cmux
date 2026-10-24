public import Foundation

/// Why a cmux credits call failed.
public nonisolated enum CloudCreditsError: Error, Sendable, Equatable {
    /// No one is signed in to cmux.
    case notSignedIn
    /// The API refused: its status, its `error.code` and `error.message` when it sent them.
    case http(status: Int, code: String?, message: String?)
    /// The answer was not the shape the API documents.
    case badResponse
    /// The request did not reach the API (offline, a timeout).
    case transport(String)
}
