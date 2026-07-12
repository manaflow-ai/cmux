import Foundation
import Testing
@testable import CmuxTerminalCore

@Suite("Prompt line turn detector")
struct PromptLineTurnDetectorTests {
    private let configuration = PromptLineTurnDetectionConfiguration(prompt: ">>> ")

    @Test("A streamed response followed by a confirmed prompt completes one turn")
    func streamedResponseCompletesTurn() throws {
        var detector = readyDetector()

        detector.consume(Data("hel".utf8))
        detector.consume(Data("lo\r\nThinking".utf8))
        detector.consume(Data(" about it...\r\nThe answer is 42.\r\n>>".utf8))
        detector.consume(Data("> ".utf8))

        let confirmation = try #require(detector.pendingConfirmation)
        #expect(detector.confirm(confirmation) == 1)
    }

    @Test("A response line beginning with prompt text invalidates the candidate")
    func promptPrefixInsideResponseDoesNotCompleteTurn() throws {
        var detector = readyDetector()

        detector.consume(Data("explain\r\nmodel output\r\n>>> ".utf8))
        let staleConfirmation = try #require(detector.pendingConfirmation)
        detector.consume(Data("not a prompt".utf8))

        #expect(detector.pendingConfirmation == nil)
        #expect(detector.confirm(staleConfirmation) == 0)
    }

    @Test("Typing echo without a submitted response never completes a turn")
    func typingEchoDoesNotCompleteTurn() throws {
        var detector = readyDetector()

        detector.consume(Data("explain >>> please".utf8))
        detector.consume(Data("\u{8}\u{8}se".utf8))

        #expect(detector.pendingConfirmation == nil)
    }

    @Test("A prompt redraw after an empty response is not a completion")
    func promptWithoutModelOutputDoesNotCompleteTurn() throws {
        var detector = readyDetector()

        detector.consume(Data("hello\r\n>>> ".utf8))
        #expect(detector.pendingConfirmation == nil)
    }

    @Test("ANSI spinner redraws count as output but cannot impersonate the prompt")
    func ansiSpinnerFramesAreHandledConservatively() throws {
        var detector = readyDetector()
        let stream = "summarize\r\n"
            + "\u{1B}[2K\r⠋ loading"
            + "\u{1B}[2K\r⠙ loading"
            + "\u{1B}[2K\rDone.\r\n"
            + ">>> "

        detector.consume(Data(stream.utf8))
        let confirmation = try #require(detector.pendingConfirmation)
        #expect(detector.confirm(confirmation) == 1)

        detector.consume(Data("still waiting at the prompt".utf8))
        #expect(detector.pendingConfirmation == nil)
    }

    @Test("Prompt text inside an OSC title is ignored")
    func oscPayloadCannotCompleteTurn() throws {
        var detector = readyDetector()
        let stream = "title\r\n"
            + "\u{1B}]0;>>> \u{7}"
            + "response\r\n>>> "

        detector.consume(Data(stream.utf8))
        let confirmation = try #require(detector.pendingConfirmation)

        #expect(detector.confirm(confirmation) == 1)
    }

    private func readyDetector() -> PromptLineTurnDetector {
        var detector = PromptLineTurnDetector(configuration: configuration)
        detector.consume(Data(">>> ".utf8))
        #expect(detector.pendingConfirmation == nil)
        return detector
    }
}
