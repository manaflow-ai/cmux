import Foundation

/// A structural config error that can be reported without importing the app's
/// AppKit-backed config model. The CLI and the published JSON Schema use the
/// same shape checks for the sections that contain executable actions.
struct CmuxConfigValidationIssue: Equatable, Sendable, CustomStringConvertible {
    let path: String
    let message: String

    var description: String {
        path + ": " + message
    }
}
