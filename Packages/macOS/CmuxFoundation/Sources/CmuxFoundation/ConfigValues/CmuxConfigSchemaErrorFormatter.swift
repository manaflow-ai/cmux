public import Foundation

/// Formats `cmux.json` schema-decoding failures into human-readable diagnostics.
///
/// Translates a Swift `DecodingError` (or any other parse error) into a
/// dotted-coding-path-prefixed message and packages it as a `CmuxConfigIssue`
/// of kind `.schemaError`. Error detail text is run through
/// `String.sanitizedCmuxConfigText` so untrusted config content cannot spoof or
/// reorder the rendered diagnostic. A value type with instance methods: hold one
/// where config decoding happens and forward decode failures to it.
public struct CmuxConfigSchemaErrorFormatter: Sendable {
    /// Creates a schema-error formatter.
    public init() {}

    /// Builds a `.schemaError` `CmuxConfigIssue` for the config file at `path`.
    ///
    /// - Parameters:
    ///   - path: The config file path the issue originated from. Its last path
    ///     component becomes the issue's `settingName`.
    ///   - message: The pre-formatted, sanitized diagnostic message.
    /// - Returns: A schema-error issue carrying `path` and `message`.
    public func schemaIssue(path: String, message: String) -> CmuxConfigIssue {
        CmuxConfigIssue(
            kind: .schemaError,
            settingName: (path as NSString).lastPathComponent,
            sourcePath: path,
            message: message
        )
    }

    /// A sanitized, coding-path-prefixed message for an arbitrary decode error.
    ///
    /// `DecodingError` cases are dispatched to the context-based formatter (with
    /// the missing key appended for `keyNotFound`); any other error falls back to
    /// its sanitized `localizedDescription`, or `String(describing:)` when that is
    /// empty.
    public func schemaErrorMessage(_ error: any Error) -> String {
        switch error {
        case DecodingError.typeMismatch(_, let context):
            return schemaErrorMessage(context)
        case DecodingError.valueNotFound(_, let context):
            return schemaErrorMessage(context)
        case DecodingError.keyNotFound(let key, let context):
            let path = schemaCodingPath(context.codingPath + [key])
            let detail = context.debugDescription.sanitizedCmuxConfigText
            return "\(path): \(detail)"
        case DecodingError.dataCorrupted(let context):
            return schemaErrorMessage(context)
        default:
            let message = error.localizedDescription.sanitizedCmuxConfigText
            return message.isEmpty ? String(describing: error) : message
        }
    }

    /// A sanitized, coding-path-prefixed message for a decoding-error context.
    ///
    /// Returns just the dotted coding path when the context has no detail, else
    /// `<path>: <sanitized detail>`.
    public func schemaErrorMessage(_ context: DecodingError.Context) -> String {
        let path = schemaCodingPath(context.codingPath)
        let detail = context.debugDescription.sanitizedCmuxConfigText
        return detail.isEmpty ? path : "\(path): \(detail)"
    }

    /// Renders a coding path as dot-joined non-empty key names, or `"root"`.
    ///
    /// - Parameter codingPath: The coding keys leading to the failure.
    /// - Returns: The dotted path, or `"root"` when no non-empty keys remain.
    public func schemaCodingPath(_ codingPath: [any CodingKey]) -> String {
        let path = codingPath.map(\.stringValue).filter { !$0.isEmpty }.joined(separator: ".")
        return path.isEmpty ? "root" : path
    }
}
