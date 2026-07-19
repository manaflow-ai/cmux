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

    @Test("An approved idle placeholder completes a current Ollama turn")
    func currentOllamaIdlePlaceholderCompletesTurn() throws {
        let currentOllamaConfiguration = PromptLineTurnDetectionConfiguration(
            prompt: ">>> ",
            waitingPromptSuffixes: ["Send a message (/? for help)"]
        )
        var detector = PromptLineTurnDetector(configuration: currentOllamaConfiguration)

        detector.consume(Data(">>> Send a message (/? for help)".utf8))
        detector.consume(Data("\r>>> Return FINAL_OLLAMA_OK\r\nFINAL_OLLAMA_OK\r\n".utf8))
        detector.consume(Data(">>> Send a message (/? for help)".utf8))

        let confirmation = try #require(detector.pendingConfirmation)
        #expect(detector.confirm(confirmation) == 1)
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

    @Test("Each echoed submission increments the submission count once")
    func submissionCountTracksEchoedSubmissions() throws {
        var detector = readyDetector()
        #expect(detector.submissionCount == 0)

        detector.consume(Data("first\r\n".utf8))
        #expect(detector.submissionCount == 1)

        detector.consume(Data("output\r\n>>> ".utf8))
        let confirmation = try #require(detector.pendingConfirmation)
        #expect(detector.confirm(confirmation) == 1)
        #expect(detector.submissionCount == 1)

        detector.consume(Data("second\r\n".utf8))
        #expect(detector.submissionCount == 2)
    }

    @Test("A pathological run of invisible bytes cannot wedge turn detection")
    func longInvisiblePrefixLineRemainsDetectable() throws {
        var detector = readyDetector()
        detector.consume(Data("ask\r\n".utf8))

        detector.consume(Data(String(repeating: " ", count: 8_192).utf8))
        #expect(detector.pendingConfirmation == nil)

        detector.consume(Data("\r\nvisible tail\r\n>>> ".utf8))
        let confirmation = try #require(detector.pendingConfirmation)
        #expect(detector.confirm(confirmation) == 1)
    }

    @Test("Backspaced typing that restores the prompt can still confirm a turn")
    func backspaceRestoresPromptCandidate() throws {
        var detector = readyDetector()
        detector.consume(Data("ask\r\nanswer\r\n".utf8))

        detector.consume(Data(">>> x".utf8))
        #expect(detector.pendingConfirmation == nil)

        detector.consume(Data("\u{7F}".utf8))
        let confirmation = try #require(detector.pendingConfirmation)
        #expect(detector.confirm(confirmation) == 1)
    }

    @Test("A pasted submission longer than the storage cap still starts a turn")
    func oversizedPastedSubmissionStartsTurn() throws {
        var detector = readyDetector()

        detector.consume(Data((String(repeating: "a", count: 5_000) + "\r\n").utf8))
        #expect(detector.submissionCount == 1)

        detector.consume(Data("output\r\n>>> ".utf8))
        let confirmation = try #require(detector.pendingConfirmation)
        #expect(detector.confirm(confirmation) == 1)
    }

    @Test("Backspacing an overflowed submission fails closed at the boundary")
    func backspacedOverflowedSubmissionDoesNotStartTurn() throws {
        var detector = readyDetector()

        // Spaces after the prompt store without tripping the printable-run
        // skip (visible count stays at the prompt's), so the line genuinely
        // overflows the storage cap. A visible byte then latches the
        // overflowed-submission snapshot.
        detector.consume(Data(String(repeating: " ", count: 5_000).utf8))
        detector.consume(Data("a".utf8))
        // Erasing from an overflowed line makes its exact content
        // unknowable, so the boundary must not count a submission from the
        // latched snapshot.
        detector.consume(Data("\u{7F}".utf8))
        detector.consume(Data("\r".utf8))
        #expect(detector.submissionCount == 0)
    }

    @Test("An oversized response line still counts as observed output")
    func oversizedOutputLineMarksObservedOutput() throws {
        var detector = readyDetector()
        detector.consume(Data("ask\r\n".utf8))

        detector.consume(Data(String(repeating: "x", count: 5_000).utf8))
        detector.consume(Data("\r\n>>> ".utf8))

        let confirmation = try #require(detector.pendingConfirmation)
        #expect(detector.confirm(confirmation) == 1)
    }

    @Test("A long preamble line does not affect initial prompt detection")
    func longPreambleLineStillDetectsPrompt() throws {
        var detector = PromptLineTurnDetector(configuration: configuration)

        detector.consume(Data((String(repeating: "log ", count: 2_000) + "\r\n").utf8))
        detector.consume(Data(">>> ".utf8))
        detector.consume(Data("hi\r\nanswer\r\n>>> ".utf8))

        let confirmation = try #require(detector.pendingConfirmation)
        #expect(detector.confirm(confirmation) == 1)
    }

    @Test("Backspaces across skipped bytes keep line editing exact")
    func backspacesAcrossSkippedBytesStayExact() throws {
        var detector = readyDetector()

        detector.consume(Data("hello".utf8))
        detector.consume(Data(String(repeating: "\u{7F}", count: 5).utf8))
        detector.consume(Data("ok\r\n".utf8))
        #expect(detector.submissionCount == 1)

        detector.consume(Data("out\r\n>>> ".utf8))
        let confirmation = try #require(detector.pendingConfirmation)
        #expect(detector.confirm(confirmation) == 1)
    }

    @Test("A submission padded past the cap with spaces still starts a turn")
    func overflowedPaddedSubmissionStartsTurn() throws {
        var detector = readyDetector()

        detector.consume(Data(String(repeating: " ", count: 5_000).utf8))
        detector.consume(Data("hello\r\n".utf8))
        #expect(detector.submissionCount == 1)

        detector.consume(Data("output\r\n>>> ".utf8))
        let confirmation = try #require(detector.pendingConfirmation)
        #expect(detector.confirm(confirmation) == 1)
    }

    @Test("Visible output after an invisible overflow still completes the turn")
    func visibleOutputAfterInvisibleOverflowCompletesTurn() throws {
        var detector = readyDetector()
        detector.consume(Data("ask\r\n".utf8))

        detector.consume(Data(String(repeating: " ", count: 5_000).utf8))
        detector.consume(Data("done\r\n>>> ".utf8))

        let confirmation = try #require(detector.pendingConfirmation)
        #expect(detector.confirm(confirmation) == 1)
    }

    @Test("Spinner redraws via CSI 1G/2K do not poison Ollama prompt detection")
    func spinnerRedrawsDoNotPoisonPromptDetection() throws {
        // Byte idioms captured from a real `ollama run` PTY: the model-load
        // spinner redraws its braille frame in place with CSI 1G + CSI K and
        // never emits CR/LF, then the idle prompt is drawn after CSI 2K.
        let ollamaConfiguration = PromptLineTurnDetectionConfiguration(
            prompt: ">>> ",
            waitingPromptSuffixes: ["Send a message (/? for help)"]
        )
        var detector = PromptLineTurnDetector(configuration: ollamaConfiguration)

        detector.consume(Data("Last login: Sat Jul 11 19:53:41 on ttys151\r\n".utf8))
        for frame in ["⠙", "⠹", "⠸", "⠼"] {
            detector.consume(Data("\u{1B}[?2026h\u{1B}[?25l\u{1B}[1G\(frame) \u{1B}[K\u{1B}[?25h\u{1B}[?2026l".utf8))
        }
        detector.consume(Data("\u{1B}[2K\u{1B}[1G\u{1B}[?25h\u{1B}[?2004h>>> \u{1B}[38;5;245mSend a message (/? for help)\u{1B}[28D\u{1B}[0m".utf8))

        detector.consume(Data("\u{1B}[Kname one metal, one word\r\n".utf8))
        #expect(detector.submissionCount == 1)

        detector.consume(Data("\u{1B}[?2026h\u{1B}[?25l\u{1B}[1G⠙ \u{1B}[K\u{1B}[?25h\u{1B}[?2026l".utf8))
        detector.consume(Data("\u{1B}[2K\u{1B}[1G\u{1B}[38;5;245m\u{1B}[1mThinking...\r\n".utf8))
        detector.consume(Data("\u{1B}[0mIron.\r\n\r\n".utf8))
        detector.consume(Data("\u{1B}[?2026h\u{1B}[?25l\u{1B}[1G⠙ \u{1B}[K\u{1B}[?25h\u{1B}[?2026l".utf8))
        detector.consume(Data("\u{1B}[2K\u{1B}[1G\u{1B}[?25h>>> \u{1B}[38;5;245mSend a message (/? for help)\u{1B}[28D\u{1B}[0m\u{1B}[K".utf8))

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
