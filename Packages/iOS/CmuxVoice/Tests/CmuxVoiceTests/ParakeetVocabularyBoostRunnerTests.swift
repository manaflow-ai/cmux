import Foundation
import Testing
@testable import CmuxVoice

@Suite struct ParakeetVocabularyBoostRunnerTests {
    @Test func noAddOnDoesNotConfigureVocabularyBoosting() async {
        let counter = VocabularyBoostConfigureCounter()
        let runner = ParakeetVocabularyBoostRunner(vocabularyTerms: ["cmux"], directory: nil)

        let configured = await runner.configure { _, _ in
            await counter.increment()
        } onFailure: { _ in
            Issue.record("No add-on should skip configuration, not fail.")
        }

        #expect(configured == false)
        #expect(await counter.value == 0)
    }

    @Test func installedAddOnConfiguresVocabularyBoosting() async {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("CmuxVoiceBoostRunnerTests-\(UUID().uuidString)", isDirectory: true)
        let counter = VocabularyBoostConfigureCounter()
        let runner = ParakeetVocabularyBoostRunner(vocabularyTerms: ["cmux"], directory: directory)

        let configured = await runner.configure { context, configuredDirectory in
            #expect(configuredDirectory == directory)
            #expect(context.terms.map(\.text) == ["cmux"])
            await counter.increment()
        } onFailure: { error in
            Issue.record("Configuration should not fail: \(error)")
        }

        #expect(configured == true)
        #expect(await counter.value == 1)
    }

    @Test func configurationFailureIsSwallowed() async {
        struct BoostFailure: Error {}
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("CmuxVoiceBoostRunnerTests-\(UUID().uuidString)", isDirectory: true)
        let runner = ParakeetVocabularyBoostRunner(vocabularyTerms: ["cmux"], directory: directory)

        let configured = await runner.configure { _, _ in
            throw BoostFailure()
        } onFailure: { _ in }

        #expect(configured == false)
    }
}

private actor VocabularyBoostConfigureCounter {
    private var count = 0

    var value: Int { count }

    func increment() {
        count += 1
    }
}
