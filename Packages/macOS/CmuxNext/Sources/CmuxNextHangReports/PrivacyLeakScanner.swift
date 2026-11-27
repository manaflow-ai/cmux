public import Foundation

/// The last check before a report leaves the Mac: walks every key and string value of the encoded
/// JSON and lists each one that could carry private data. A report with any finding is not sent.
///
/// A string may hold only letters, digits, space and `. _ + ( ) -` (so no path, email, URL,
/// address, time, assignment or quote), at most 128 characters, no run of 32 or more letters and
/// digits that mixes both (a token), and none of ``forbiddenTerms`` (the user's names, home
/// folder, host name), compared case-insensitively. A finding names the JSON path only, never
/// the value.
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
        walk(root, path: "$", into: &found)
        return found
    }

    private func walk(_ value: Any, path: String, into found: inout [Finding]) {
        switch value {
        case let object as [String: Any]:
            for (key, child) in object {
                // Keys are the schema's names: checked for shape, not for personal terms.
                let keyKind = kind(of: key, personal: false)
                if let keyKind { found.append(Finding(path: path + ".<key>", kind: keyKind)) }
                walk(child, path: path + "." + (keyKind == nil ? key : "<key>"), into: &found)
            }
        case let array as [Any]:
            for (index, child) in array.enumerated() { walk(child, path: "\(path)[\(index)]", into: &found) }
        case let string as String:
            if let kind = kind(of: string) { found.append(Finding(path: path, kind: kind)) }
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
