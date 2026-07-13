/// Thrown by ``MultiWindowRouting/route(arguments:)`` when the cmux CLI
/// process could not be launched at all (the executable is missing, not
/// executable, or `posix_spawn` failed).
///
/// This is the only error the route throws; once the CLI launches, every
/// outcome (including non-zero exit) is data in ``MultiWindowRouteResult``.
/// `description` preserves the underlying Foundation error's
/// `String(describing:)` text verbatim, so callers that re-encode the legacy
/// `"-1"` capture (`String(describing: error)` into the UI-test data file)
/// produce byte-identical output to the pre-extraction code.
public struct MultiWindowRouteLaunchError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The underlying launch error rendered with `String(describing:)`,
    /// preserved verbatim for the legacy capture encoding.
    public let description: String

    /// Creates a launch error.
    /// - Parameter description: The underlying error's `String(describing:)`
    ///   text.
    public init(description: String) {
        self.description = description
    }
}
