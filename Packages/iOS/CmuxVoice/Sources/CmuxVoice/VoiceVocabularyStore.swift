public import Foundation
public import Observation

/// Persists custom vocabulary terms used to bias voice recognition.
@MainActor
@Observable
public final class VoiceVocabularyStore {
    /// Maximum number of user-authored terms stored.
    public nonisolated static let maxUserTerms = 200
    /// Maximum number of automatic screen-derived terms merged for Voice Mode.
    public nonisolated static let maxScreenTerms = 50

    private nonisolated(unsafe) let defaults: UserDefaults
    private static let termsKey = "cmux.mobile.voice.vocabulary.terms"
    private static let autoBiasScreenTermsKey = "cmux.mobile.voice.vocabulary.autoBiasScreenTerms"

    /// Ordered, case-preserving, case-insensitively unique terms.
    public var terms: [String] {
        didSet {
            let normalized = Self.normalizedTerms(terms, limit: Self.maxUserTerms)
            if normalized != terms {
                terms = normalized
            } else {
                defaults.set(terms, forKey: Self.termsKey)
            }
        }
    }

    /// Whether Voice Mode should merge words visible in the focused Mac workspace.
    public var autoBiasScreenTerms: Bool {
        didSet { defaults.set(autoBiasScreenTerms, forKey: Self.autoBiasScreenTermsKey) }
    }

    /// Creates a vocabulary store backed by injected defaults.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.terms = Self.normalizedTerms(
            defaults.stringArray(forKey: Self.termsKey) ?? [],
            limit: Self.maxUserTerms
        )
        if defaults.object(forKey: Self.autoBiasScreenTermsKey) == nil {
            self.autoBiasScreenTerms = true
        } else {
            self.autoBiasScreenTerms = defaults.bool(forKey: Self.autoBiasScreenTermsKey)
        }
    }

    /// Adds a term after trimming and de-duplicating.
    @discardableResult
    public func addTerm(_ term: String) -> Bool {
        let normalized = Self.normalizedTerms([term], limit: 1)
        guard let value = normalized.first else { return false }
        guard !terms.contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) else {
            return false
        }
        terms = Self.normalizedTerms(terms + [value], limit: Self.maxUserTerms)
        return terms.contains { $0.caseInsensitiveCompare(value) == .orderedSame }
    }

    /// Removes terms at list offsets.
    public func removeTerms(at offsets: IndexSet) {
        for offset in offsets.sorted(by: >) where terms.indices.contains(offset) {
            terms.remove(at: offset)
        }
    }

    /// Terms to pass into a recognition engine for one session.
    public func recognitionTerms(screenStrings: [String] = []) -> [String] {
        let screenTerms = autoBiasScreenTerms
            ? VoiceVocabularyScreenTermTokenizer().tokenize(screenStrings, limit: Self.maxScreenTerms)
            : []
        return Self.normalizedTerms(terms + screenTerms, limit: Self.maxUserTerms + Self.maxScreenTerms)
    }

    /// Normalizes a term list while preserving the first casing encountered.
    public nonisolated static func normalizedTerms(_ values: [String], limit: Int) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            guard seen.insert(key).inserted else { continue }
            result.append(trimmed)
        }
        guard result.count > limit else { return result }
        return Array(result.suffix(limit))
    }
}
