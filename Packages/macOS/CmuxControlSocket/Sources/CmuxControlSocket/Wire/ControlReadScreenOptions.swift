internal import Foundation

/// Parsed options for the v1 `read_screen [id|idx] [--scrollback] [--lines N]`
/// command.
///
/// A pure, `Sendable` value produced by ``parse(_:)`` from the raw v1 argument
/// string. The tokenizer is byte-faithful to the legacy god-file
/// `parseReadScreenArgs(_:)`: whitespace-split tokens, `--scrollback` sets the
/// scrollback flag, `--lines N` requires a positive integer and also implies
/// scrollback, and the first bare token becomes the surface argument (a second
/// bare token is a usage error). The app-side `readScreenText` witness consumes
/// these fields to read terminal text.
public struct ControlReadScreenOptions: Sendable, Equatable {
    /// The surface identifier or index argument, or an empty string when none
    /// was supplied (matching the legacy default).
    public let surfaceArg: String
    /// Whether scrollback should be included (`--scrollback`, or implied by
    /// `--lines`).
    public let includeScrollback: Bool
    /// The maximum number of lines to read (`--lines N`), or `nil` for no limit.
    public let lineLimit: Int?

    /// Creates a parsed read-screen options value.
    ///
    /// - Parameters:
    ///   - surfaceArg: The surface identifier or index argument.
    ///   - includeScrollback: Whether scrollback should be included.
    ///   - lineLimit: The maximum number of lines to read, or `nil`.
    public init(surfaceArg: String, includeScrollback: Bool, lineLimit: Int?) {
        self.surfaceArg = surfaceArg
        self.includeScrollback = includeScrollback
        self.lineLimit = lineLimit
    }

    /// A read-screen argument-parse failure carrying the verbatim v1 wire error
    /// string to return to the client.
    public struct ParseError: Error, Sendable, Equatable {
        /// The wire error message (e.g. `"ERROR: --lines must be greater than 0"`).
        public let message: String

        /// Creates a parse error.
        ///
        /// - Parameter message: The verbatim wire error message.
        public init(message: String) {
            self.message = message
        }
    }

    /// Tokenizes the raw `read_screen` argument string into options.
    ///
    /// Byte-faithful to the legacy `parseReadScreenArgs(_:)`: arguments are
    /// split on whitespace; `--scrollback` enables scrollback; `--lines`
    /// consumes the next token, which must parse as an integer greater than 0
    /// (otherwise a failure is returned) and implies scrollback; the first bare
    /// token sets the surface argument and a second bare token is a usage
    /// failure. When no surface argument is supplied it defaults to the empty
    /// string.
    ///
    /// - Parameter args: The raw argument substring following `read_screen`.
    /// - Returns: The parsed options, or a ``ParseError`` with the wire message.
    public static func parse(_ args: String) -> Result<ControlReadScreenOptions, ParseError> {
        let tokens = args
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        var surfaceArg: String?
        var includeScrollback = false
        var lineLimit: Int?
        var idx = 0

        while idx < tokens.count {
            let token = tokens[idx]
            switch token {
            case "--scrollback":
                includeScrollback = true
                idx += 1
            case "--lines":
                guard idx + 1 < tokens.count, let parsed = Int(tokens[idx + 1]), parsed > 0 else {
                    return .failure(ParseError(message: "ERROR: --lines must be greater than 0"))
                }
                lineLimit = parsed
                includeScrollback = true
                idx += 2
            default:
                guard surfaceArg == nil else {
                    return .failure(ParseError(message: "ERROR: Usage: read_screen [id|idx] [--scrollback] [--lines <n>]"))
                }
                surfaceArg = token
                idx += 1
            }
        }

        return .success(
            ControlReadScreenOptions(
                surfaceArg: surfaceArg ?? "",
                includeScrollback: includeScrollback,
                lineLimit: lineLimit
            )
        )
    }
}
