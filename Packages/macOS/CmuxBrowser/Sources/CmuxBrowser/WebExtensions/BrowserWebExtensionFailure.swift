import Foundation

/// Describes a stable, sanitized WebExtension lifecycle failure.
public enum BrowserWebExtensionFailure: String, Codable, Equatable, Sendable {
    /// Extension loading exceeded the profile runtime deadline.
    case loadDeadlineExceeded

    /// Extension discovery or loading failed before readiness.
    case loadFailed

    /// WebExtensions are unavailable on the running operating system.
    case unsupported
}
