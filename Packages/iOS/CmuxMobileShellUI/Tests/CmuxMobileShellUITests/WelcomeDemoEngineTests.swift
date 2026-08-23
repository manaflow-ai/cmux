#if os(iOS)
import Testing

@testable import CmuxMobileShellUI

/// Behavior tests for the welcome demo engine's instant (deterministic) path.
///
/// Instant mode is exactly what the UI-test preview and Reduce Motion use, and
/// it exercises the same step application as clocked playback.
@MainActor
@Suite struct WelcomeDemoEngineTests {
    private func makeEngine() -> WelcomeDemoEngine {
        WelcomeDemoEngine(script: WelcomeDemoScript(), revealsInstantly: true)
    }

    @Test func playbackRevealsTranscriptAndPausesOnTheQuestion() {
        let engine = makeEngine()
        #expect(engine.phase == .idle)

        engine.start()

        #expect(engine.phase == .awaitingReply)
        #expect(engine.question != nil)
        // Every step up to and including the question prompt is on screen.
        #expect(engine.lines.count == 5)
        #expect(engine.lines.first?.style == .command)
    }

    @Test func startingTwiceDoesNotReplay() {
        let engine = makeEngine()
        engine.start()
        let revealed = engine.lines

        engine.start()

        #expect(engine.lines == revealed)
    }

    @Test func choosingAReplyEchoesItAndFinishes() throws {
        let engine = makeEngine()
        engine.start()
        let question = try #require(engine.question)
        let reply = try #require(question.replies.first)

        engine.choose(reply)

        #expect(engine.phase == .finished)
        #expect(engine.question == nil)
        let echoed = engine.lines.first { $0.style == .reply }
        #expect(echoed?.text == reply.echo)
        #expect(engine.lines.last?.style == .success)
    }

    @Test func everyReplyResolvesTheDemo() throws {
        let question = try #require(questionFromScript())
        for reply in question.replies {
            let engine = makeEngine()
            engine.start()
            engine.choose(reply)
            #expect(engine.phase == .finished)
        }
    }

    @Test func choosingBeforeTheQuestionIsIgnored() throws {
        let engine = makeEngine()
        let question = try #require(questionFromScript())

        engine.choose(question.replies[0])

        #expect(engine.phase == .idle)
        #expect(engine.lines.isEmpty)
    }

    private func questionFromScript() -> WelcomeDemoQuestion? {
        for step in WelcomeDemoScript().steps {
            if case .question(let question) = step {
                return question
            }
        }
        return nil
    }
}
#endif
