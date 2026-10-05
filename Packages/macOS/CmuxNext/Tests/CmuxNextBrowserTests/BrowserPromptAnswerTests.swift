import Foundation
import Testing
@testable import CmuxNextBrowser

/// The prompt bar's permission question answers without the mouse
/// (`browser.prompt.allow` / `browser.prompt.block`): only the first
/// pending prompt, and only when it is a permission question.
@MainActor
@Suite struct BrowserPromptAnswerTests {
    final class Recorder {
        var responses: [BrowserPromptResponse] = []

        func prompt(_ kind: BrowserPromptKind) -> BrowserPrompt {
            BrowserPrompt(kind: kind, origin: "https://files.example") { [self] in responses.append($0) }
        }
    }

    @Test func allowAnswersTheShownPermissionQuestion() {
        let recorder = Recorder()
        let first = recorder.prompt(.permission(.automaticDownloads))
        let second = recorder.prompt(.permission(.camera))
        #expect(BrowserPrompt.answerFirstPermission(.allow, in: [first, second]))
        #expect(recorder.responses == [.allow])
        #expect(first.isResolved)
        #expect(!second.isResolved)
    }

    @Test func blockAnswersNeverAllow() {
        let recorder = Recorder()
        let first = recorder.prompt(.permission(.automaticDownloads))
        #expect(BrowserPrompt.answerFirstPermission(.block, in: [first]))
        #expect(recorder.responses == [.deny])
    }

    @Test func nothingToAnswer() {
        let recorder = Recorder()
        let alert = recorder.prompt(.alert(message: "Hi"))
        #expect(!BrowserPrompt.answerFirstPermission(.allow, in: []))
        #expect(!BrowserPrompt.answerFirstPermission(.allow, in: [alert, recorder.prompt(.permission(.camera))]))
        #expect(recorder.responses.isEmpty)
        #expect(!alert.isResolved)
    }
}
