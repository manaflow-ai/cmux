public import Foundation

/// The last check before a report leaves the Mac: walks every key and string value of the encoded
/// JSON and lists each one that could carry private data. A report with any finding is not sent.
///
/// A string may hold only letters, digits, space and `. _ + ( ) -` (so no path, email, URL,
/// address, time, assignment or quote), at most 128 characters, no run of 32 or more letters and
/// digits that mixes both (a token), and none of ``forbiddenTerms`` (the user's names, home
/// folder, host name), compared case-insensitively. A finding names the JSON path only, never
/// the value. A field whose values form a catalog (``catalogValues``: the histogram names, the black box's
/// processes) holds only a member of it.
///
/// ```swift
/// let findings = PrivacyLeakScanner(forbiddenTerms: ImageClassifier.personalTerms()).findings(in: body)
/// guard findings.isEmpty else { return .refused(findings) }
/// ```
public nonisolated struct PrivacyLeakScanner: Sendable {
    /// What a string looked like.
    public enum Kind: String, Sendable, Equatable {
        case notJSON
        case unsafeCharacter
        case tooLong
        case token
        case personalTerm
        /// A value outside its field's catalog (``catalogValues``).
        case notInCatalog
    }

    /// One finding: where, and what it looked like.
    public struct Finding: Sendable, Equatable, CustomStringConvertible {
        /// Where in the JSON (never the value).
        public var path: String
        /// How long it was.
        public var kind: Kind
        /// The finding as a log line (kind and path only).
        public var description: String { "\(kind.rawValue) at \(path)" }
    }

    /// The longest string a report may hold.
    public static let maxStringLength = 128
    private static let safeCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 ._+()-")

    private let forbiddenTerms: @Sendable () -> [String]

    /// - Parameter forbiddenTerms: Words no string may hold (``ImageClassifier/personalTerms()``);
    ///   terms under 4 letters, and words of the report's own vocabulary, are ignored. Read at
    ///   each scan, never at init: the app passes a value computed once off the main thread.
    public init(forbiddenTerms: @autoclosure @escaping @Sendable () -> [String]) {
        self.forbiddenTerms = { ImageClassifier.normalizedTerms(forbiddenTerms()) }
    }

    /// Every finding in `json` (empty: safe to send).
    public func findings(in json: Data) -> [Finding] {
        guard let root = try? JSONSerialization.jsonObject(with: json, options: [.fragmentsAllowed]) else {
            return [Finding(path: "$", kind: .notJSON)]
        }
        var found: [Finding] = []
        walk(root, path: "$", schemaPath: "$", into: &found)
        return found
    }

    /// The fields whose values come only from a closed set, by schema path (array indices as
    /// `[]`): the input enums' case names and Chrome's scroll jank histogram names. A string that
    /// is exactly a member, at its own path, is not checked for personal terms (a person named
    /// Mina and the target `terminal`); any other value there, and every other string, is.
    static let closedSetValues: [String: Set<String>] = [
        "$.input_latency[].kind": HangReportBuilder.inputKinds,
        "$.input_latency[].target": HangReportBuilder.inputTargets,
        "$.input_latency[].entrypoint": HangReportBuilder.inputEntrypoints,
        "$.input_latency[].presentation_source": HangReportBuilder.presentationSources,
        "$.scroll_jank.histograms[].name": HangReportBuilder.scrollJankNames,
        "$.interaction_latency.kind_of_worst": HangReport.InteractionLatency.kinds,
    ]

    /// The fields that hold only a catalog member, by schema path: schema 3's histogram names (this build's
    /// ``HistogramID`` catalog) and black-box processes. Any other value there is refused.
    static let catalogValues: [String: Set<String>] = [
        "$.histograms[].name": HangReport.histogramCatalog,
        "$.launch_sections[].histograms[].name": HangReport.histogramCatalog,
        "$.blackbox[].process": HangReport.blackBoxProcesses,
    ]

    /// The fields that hold a hash (schema 3's blocking site ids, ``HangReport/BlockingSiteCount/siteID(location:)``),
    /// by schema path: a value of exactly 16 lowercase hex digits there is a hash and holds no text, so it is not
    /// checked for personal terms (a person named Abbe and the id `0abbe12f3c4d5e6f`); any other value there is.
    static let hashPaths: Set<String> = ["$.blocking_sites[].site"]

    private func walk(_ value: Any, path: String, schemaPath: String, into found: inout [Finding]) {
        switch value {
        case let object as [String: Any]:
            for (key, child) in object {
                // Keys are the schema's names: checked for shape, not for personal terms.
                let keyKind = kind(of: key, personal: false)
                if let keyKind { found.append(Finding(path: path + ".<key>", kind: keyKind)) }
                let name = keyKind == nil ? key : "<key>"
                walk(child, path: path + "." + name, schemaPath: schemaPath + "." + name, into: &found)
            }
        case let array as [Any]:
            for (index, child) in array.enumerated() {
                walk(child, path: "\(path)[\(index)]", schemaPath: schemaPath + "[]", into: &found)
            }
        case let string as String:
            if let catalog = Self.catalogValues[schemaPath] {
                if !catalog.contains(string) { found.append(Finding(path: path, kind: .notInCatalog)) }
                return
            }
            let closedSetMember = Self.closedSetValues[schemaPath]?.contains(string) ?? false
            let hash = Self.hashPaths.contains(schemaPath)
                && string.range(of: HangReportBuilder.blockingSitePattern, options: .regularExpression) != nil
            if let kind = kind(of: string, personal: !closedSetMember && !hash) { found.append(Finding(path: path, kind: kind)) }
        default:
            break
        }
    }

    /// What is wrong with `text`, nil when it may be sent.
    func kind(of text: String, personal: Bool = true) -> Kind? {
        if text.count > Self.maxStringLength { return .tooLong }
        if text.unicodeScalars.contains(where: { !Self.safeCharacters.contains($0) }) { return .unsafeCharacter }
        if ImageClassifier.isUUID(text) { return nil }
        if Self.hasTokenRun(text) { return .token }
        let lowered = text.lowercased()
        if personal, forbiddenTerms().contains(where: { lowered.contains($0) }) { return .personalTerm }
        return nil
    }

    /// A run of 32 or more letters and digits holding both.
    static func hasTokenRun(_ text: String) -> Bool {
        var length = 0
        var letters = false
        var digits = false
        for character in text {
            if character.isASCII && (character.isLetter || character.isNumber) {
                length += 1
                letters = letters || character.isLetter
                digits = digits || character.isNumber
                if length >= 32 && letters && digits { return true }
            } else {
                length = 0
                letters = false
                digits = false
            }
        }
        return false
    }
}
