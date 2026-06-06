import Foundation

/// Masks obvious secret patterns in assembled diagnostics text before it leaves
/// the device.
///
/// The diagnostics bundle is shared to multiple internal testers through the
/// system share sheet, and both the terminal snapshot and the log lines can
/// carry live credentials (bearer tokens, API keys, JWTs, `password=` values).
/// ``scrub(_:)`` runs a small set of conservative regular expressions over the
/// whole report and replaces only the secret value with ``redactionMarker``,
/// leaving surrounding text intact.
///
/// The intent is *light* masking, not aggressive sanitization: it must not
/// mangle ordinary terminal output, dotted identifiers (`dev.cmux.ios`), or
/// version strings (`1.2.3`). Each pattern requires structure that ordinary
/// output does not accidentally satisfy (a recognized prefix, a long
/// base64url-charset run, or a `key=value` secret keyword).
///
/// ```swift
/// let scrubber = MobileDiagnosticsSecretScrubber()
/// let clean = scrubber.scrub("Authorization: Bearer abc.def.ghi")
/// // -> "Authorization: Bearer <redacted>"
/// ```
public struct MobileDiagnosticsSecretScrubber: Sendable {
    /// The replacement written in place of a matched secret value.
    public let redactionMarker: String

    private let patterns: [(regex: NSRegularExpression, valueGroup: Int)]

    /// Creates a scrubber.
    ///
    /// - Parameter redactionMarker: The text substituted for each masked secret.
    ///   Defaults to `"<redacted>"`.
    public init(redactionMarker: String = "<redacted>") {
        self.redactionMarker = redactionMarker
        self.patterns = MobileDiagnosticsSecretPatternFactory().makePatterns()
    }

    /// Returns `text` with recognized secret values replaced by ``redactionMarker``.
    ///
    /// Patterns are applied in sequence; a value masked by one pattern is no
    /// longer a candidate for later ones. Non-secret text (identifiers, version
    /// numbers, ordinary output) is left untouched.
    ///
    /// - Parameter text: The assembled report text to scrub.
    /// - Returns: The scrubbed text.
    public func scrub(_ text: String) -> String {
        var result = text
        for pattern in patterns {
            result = replaceSecretGroup(
                in: result,
                regex: pattern.regex,
                group: pattern.valueGroup,
                with: redactionMarker
            )
        }
        return result
    }

    /// Replace the contents of one capture group across every match, scanning from
    /// the end so earlier match ranges stay valid as the string mutates.
    private func replaceSecretGroup(
        in text: String,
        regex: NSRegularExpression,
        group: Int,
        with replacement: String
    ) -> String {
        let nsText = text as NSString
        let matches = regex.matches(
            in: text,
            range: NSRange(location: 0, length: nsText.length)
        )
        let mutable = (nsText.mutableCopy() as? NSMutableString) ?? NSMutableString(string: text)
        for match in matches.reversed() {
            guard match.numberOfRanges > group else { continue }
            let valueRange = match.range(at: group)
            guard valueRange.location != NSNotFound else { continue }
            mutable.replaceCharacters(in: valueRange, with: replacement)
        }
        return mutable as String
    }
}
