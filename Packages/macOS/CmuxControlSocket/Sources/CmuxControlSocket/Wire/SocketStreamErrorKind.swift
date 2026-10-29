/// The kind of plain-text error a stream endpoint returned before its JSON
/// protocol began.
///
/// The control-socket package owns this wire-level classification. The CLI
/// remains responsible for converting the result into a localized `CLIError`
/// because localization resources belong to the executable.
public enum SocketStreamErrorKind: Equatable, Sendable {
    /// The server rejected the client because of the socket access policy.
    case accessDenied
    /// The server returned another plain-text error response.
    case server

    /// Classifies one raw line from a v2 stream.
    ///
    /// A localized access-denied response is supplied by the caller because
    /// the package deliberately has no dependency on the app's localization
    /// catalog. The English protocol prefix remains recognized for backwards
    /// compatibility with older servers and test fixtures.
    ///
    /// - Parameters:
    ///   - line: The raw, newline-stripped stream line.
    ///   - localizedAccessDeniedResponse: The localized `ERROR:` response the
    ///     server may emit for an access-policy rejection.
    /// - Returns: ``accessDenied`` or ``server`` for an `ERROR:` line, or
    ///   `nil` when the line is part of the normal stream protocol.
    public static func classify(
        line: String,
        localizedAccessDeniedResponse: String? = nil
    ) -> Self? {
        guard line.hasPrefix("ERROR:") else { return nil }

        if let localizedAccessDeniedResponse,
           line == localizedAccessDeniedResponse {
            return .accessDenied
        }
        if line.hasPrefix("ERROR: Access denied") {
            return .accessDenied
        }
        return .server
    }
}
