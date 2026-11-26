public import Foundation

/// The last check before a report leaves the Mac: every key and string value of the encoded JSON
/// that could carry private data. A report with any finding is not sent.
///
/// A string may hold only letters, digits, space and `. _ + ( ) -`, at most 128 characters, no
/// run of 32 or more letters and digits that mixes both (a token), and none of the person's words.
/// A finding names the JSON path only, never the value. The scan is Rust's
/// (cmux-tui/crates/cmux-hang-report), asked through ``HangReportRules``.
///
/// ```swift
/// let findings = PrivacyLeakScanner(forbiddenTerms: ImageClassifier.personalTerms()).findings(in: body)
/// guard findings.isEmpty else { return .refused(findings) }
/// ```
public nonisolated struct PrivacyLeakScanner: Sendable {
    /// What a string looked like.
    public enum Kind: String, Sendable, Equatable, Decodable {
        case notJSON
        case unsafeCharacter
        case tooLong
        case token
        case personalTerm
    }

    /// One finding: where, and what it looked like.
    public struct Finding: Sendable, Equatable, Decodable, CustomStringConvertible {
        /// Where in the JSON (never the value).
        public var path: String
        /// How long it was.
        public var kind: Kind
        /// The finding as a log line (kind and path only).
        public var description: String { "\(kind.rawValue) at \(path)" }
    }

    /// The raw personal terms, read at each scan.
    let terms: @Sendable () -> [String]

    /// - Parameter forbiddenTerms: Words no string may hold (``ImageClassifier/personalTerms()``);
    ///   terms under 4 letters, and words of the report's own vocabulary, are ignored. Read at
    ///   each scan, never at init: the app passes a value computed once off the main thread.
    public init(forbiddenTerms: @autoclosure @escaping @Sendable () -> [String]) {
        self.terms = forbiddenTerms
    }

    /// Every finding in `json` (empty: safe to send). When the rules do not answer, one
    /// ``Kind/notJSON`` finding, so nothing is sent.
    public func findings(in json: Data) -> [Finding] {
        struct Request: Encodable {
            var body: String
            var forbiddenTerms: [String]
        }
        guard let body = String(data: json, encoding: .utf8) else { return [Finding(path: "$", kind: .notJSON)] }
        return HangReportRules.call("scan", Request(body: body, forbiddenTerms: terms()), as: HangReportRules.Findings.self)?
            .findings ?? [Finding(path: "$", kind: .notJSON)]
    }
}
