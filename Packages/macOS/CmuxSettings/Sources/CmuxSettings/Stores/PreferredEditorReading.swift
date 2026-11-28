import Foundation

/// Read access to the user's preferred editor command.
///
/// The file-open service resolves the command through this seam at each
/// open, so a settings change applies to the next open without restart.
public protocol PreferredEditorReading: Sendable {
    /// The configured editor command (e.g. `"code"`, `"subl -w"`), or `nil`
    /// to use the system default application. Whitespace-only stored values
    /// read as `nil`.
    var resolvedCommand: String? { get }
}
