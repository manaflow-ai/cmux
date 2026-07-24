import FluidAudio
import Foundation

enum ParakeetVocabularyContextFactory {
    static func makeContext(terms: [String]) -> CustomVocabularyContext? {
        let normalized = VoiceVocabularyStore.normalizedTerms(
            terms,
            limit: VoiceVocabularyStore.maxUserTerms + VoiceVocabularyStore.maxScreenTerms
        )
        guard !normalized.isEmpty else { return nil }
        return CustomVocabularyContext(
            terms: normalized.map { CustomVocabularyTerm(text: $0) }
        )
    }
}
