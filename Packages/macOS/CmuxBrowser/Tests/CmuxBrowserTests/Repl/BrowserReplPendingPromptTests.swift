import Testing

@testable import CmuxBrowser

/// The secure sign-in sheet waits for the user. When the REPL call that
/// asked ends (its cell is cancelled, the session is reset or closed), the
/// sheet must go away and its request fail, so a Fill the user presses later
/// fills nothing.
@MainActor
@Suite("Browser REPL pending prompts")
struct BrowserReplPendingPromptTests {
    private enum Answer: Sendable, Equatable {
        case filled
        case expired
        case cancelled
    }

    @Test("Cancelling the call that waits ends the prompt and takes it down")
    func cancellingTheWaitingCallEndsThePrompt() async {
        var ended = 0
        let prompt = BrowserReplPendingPrompt<Answer> { ended += 1 }
        let waiting = Task { @MainActor in
            await prompt.wait(timeout: .seconds(2), expired: .expired, cancelled: .cancelled)
        }
        // The prompt is up; then the call is cancelled.
        await Task.yield()
        waiting.cancel()
        let answer = await waiting.value
        #expect(answer == .cancelled, "the prompt outlived the call that asked")
        #expect(ended == 1, "the prompt was not taken down")
        // The user's Fill afterwards does nothing.
        prompt.finish(.filled)
        #expect(ended == 1)
    }

    @Test("A call already cancelled shows no prompt")
    func anAlreadyCancelledCallEndsAtOnce() async {
        var ended = 0
        let prompt = BrowserReplPendingPrompt<Answer> { ended += 1 }
        let waiting = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return await prompt.wait(timeout: .seconds(2), expired: .expired, cancelled: .cancelled)
        }
        #expect(await waiting.value == .cancelled)
        #expect(ended == 1)
    }

    @Test("The user's answer and the timeout end the prompt once")
    func answersEndThePromptOnce() async {
        var ended = 0
        let prompt = BrowserReplPendingPrompt<Answer> { ended += 1 }
        let waiting = Task { @MainActor in
            await prompt.wait(timeout: .seconds(60), expired: .expired, cancelled: .cancelled)
        }
        await Task.yield()
        prompt.finish(.filled)
        prompt.finish(.cancelled)
        #expect(await waiting.value == .filled)
        #expect(ended == 1)
        let quick = BrowserReplPendingPrompt<Answer> {}
        #expect(await quick.wait(timeout: .milliseconds(10), expired: .expired, cancelled: .cancelled) == .expired)
    }
}
