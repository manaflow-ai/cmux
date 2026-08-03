import Foundation
import Testing
@testable import CmuxVoice

@MainActor
@Suite struct VoiceVocabularyStoreTests {
    @Test func termsAreTrimmedDedupedCappedAndPersisted() {
        let defaults = Self.defaults()
        var store: VoiceVocabularyStore? = VoiceVocabularyStore(defaults: defaults)

        #expect(store?.autoBiasScreenTerms == true)
        #expect(store?.addTerm("  cmux  ") == true)
        #expect(store?.addTerm("CMUX") == false)
        store?.terms = (0..<205).map { "term\($0)" }
        store?.autoBiasScreenTerms = false
        store = nil

        let reloaded = VoiceVocabularyStore(defaults: defaults)
        #expect(reloaded.terms.count == VoiceVocabularyStore.maxUserTerms)
        #expect(reloaded.terms.first == "term5")
        #expect(reloaded.terms.last == "term204")
        #expect(reloaded.autoBiasScreenTerms == false)
    }

    @Test func screenTermsTokenizeVisibleTitlesAndMergeAfterUserTerms() {
        let screenTerms = VoiceVocabularyScreenTermTokenizer().tokenize([
            "cmuxterm-hq / worktree foo_bar",
            "repo.name a bc CMUX",
        ])

        #expect(screenTerms == ["cmuxterm", "worktree", "foo_bar", "repo", "name", "CMUX"])

        let store = VoiceVocabularyStore(defaults: Self.defaults())
        store.terms = ["cmux", "Ghostty"]
        let merged = store.recognitionTerms(screenStrings: ["cmux worktree Ghostty"])

        #expect(merged == ["cmux", "Ghostty", "worktree"])
    }

    @Test func parakeetContextUsesNormalizedTerms() throws {
        let context = try #require(ParakeetVocabularyContextFactory.makeContext(terms: [
            " cmux ",
            "CMUX",
            "worktree",
        ]))

        #expect(context.terms.map(\.text) == ["cmux", "worktree"])
    }

    private static func defaults() -> UserDefaults {
        let suite = "CmuxVoiceVocabularyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}
