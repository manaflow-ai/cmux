import FluidAudio
import Foundation

/// Applies optional Parakeet vocabulary boosting when the add-on is installed.
struct ParakeetVocabularyBoostRunner: Sendable {
    private let context: CustomVocabularyContext?
    private let directory: URL?

    init(vocabularyTerms: [String], directory: URL?) {
        self.context = ParakeetVocabularyContextFactory.makeContext(terms: vocabularyTerms)
        self.directory = directory
    }

    func configure(
        _ configure: @Sendable (CustomVocabularyContext, URL) async throws -> Void,
        onFailure: @Sendable (any Error) -> Void
    ) async -> Bool {
        guard let context, let directory else { return false }
        do {
            try await configure(context, directory)
            return true
        } catch {
            onFailure(error)
            return false
        }
    }
}
