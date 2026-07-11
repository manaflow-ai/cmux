import Foundation
import Testing
@testable import CmuxTerminalCore

@Suite("Prompt line turn detector")
struct PromptLineTurnDetectorTests {
    private let configuration = PromptLineTurnDetectionConfiguration(prompt: ">>> ")

    @Test("A streamed response followed by the prompt completes one turn")
    func streamedResponseCompletesTurn() {
        var detector = PromptLineTurnDetector(configuration: configuration)

        #expect(detector.consume(Data(">>> hel".utf8)) == 0)
        #expect(detector.consume(Data("lo\r\nThinking".utf8)) == 0)
        #expect(detector.consume(Data(" about it...\r\nThe answer is 42.\r\n>>".utf8)) == 0)
        #expect(detector.consume(Data("> ".utf8)) == 1)
    }

    @Test("Typing echo without a submitted response never completes a turn")
    func typingEchoDoesNotCompleteTurn() {
        var detector = PromptLineTurnDetector(configuration: configuration)

        #expect(detector.consume(Data(">>> explain >>> please".utf8)) == 0)
        #expect(detector.consume(Data("\u{8}\u{8}se".utf8)) == 0)
    }

    @Test("A prompt redraw after an empty response is not a completion")
    func promptWithoutModelOutputDoesNotCompleteTurn() {
        var detector = PromptLineTurnDetector(configuration: configuration)

        #expect(detector.consume(Data(">>> hello\r\n>>> ".utf8)) == 0)
    }

    @Test("ANSI spinner redraws count as output but cannot impersonate the prompt")
    func ansiSpinnerFramesAreHandledConservatively() {
        var detector = PromptLineTurnDetector(configuration: configuration)
        let stream = ">>> summarize\r\n"
            + "\u{1B}[2K\r⠋ loading"
            + "\u{1B}[2K\r⠙ loading"
            + "\u{1B}[2K\rDone.\r\n"
            + ">>> "

        #expect(detector.consume(Data(stream.utf8)) == 1)
        #expect(detector.consume(Data("still waiting at the prompt".utf8)) == 0)
    }

    @Test("Prompt text inside an OSC title is ignored")
    func oscPayloadCannotCompleteTurn() {
        var detector = PromptLineTurnDetector(configuration: configuration)
        let stream = ">>> title\r\n"
            + "\u{1B}]0;>>> \u{7}"
            + "response\r\n>>> "

        #expect(detector.consume(Data(stream.utf8)) == 1)
    }
}
