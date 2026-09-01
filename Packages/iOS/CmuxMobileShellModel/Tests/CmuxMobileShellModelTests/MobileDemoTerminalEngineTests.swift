import Foundation
import Testing

@testable import CmuxMobileShellModel

/// The demonstration terminal engine is a deterministic local PTY simulacrum:
/// canned history replays on mount, typed characters echo immediately, and
/// Enter runs a small canned command table. These tests pin the line
/// discipline (echo, backspace, Ctrl-C, escape filtering) and the replay
/// consistency the terminal view relies on across remounts.
@MainActor
@Suite struct MobileDemoTerminalEngineTests {
    private func makeEngine(
        transcript: String = "welcome\r\n",
        now: Date = Date(timeIntervalSince1970: 1_756_500_000)
    ) -> MobileDemoTerminalEngine {
        MobileDemoTerminalEngine(
            scripts: [
                MobileDemoTerminalScript(
                    surfaceID: "surface-1",
                    transcript: transcript,
                    prompt: "$ ",
                    workingDirectory: "/Users/demo/project",
                    files: [
                        MobileDemoTerminalFile(name: "src", isDirectory: true),
                        MobileDemoTerminalFile(name: "README.md", contents: "hello\nworld"),
                    ]
                ),
            ],
            now: { now }
        )
    }

    private func text(_ data: Data?) -> String {
        String(decoding: data ?? Data(), as: UTF8.self)
    }

    @Test func replayShowsTranscriptAndPrompt() {
        let engine = makeEngine()
        #expect(text(engine.replayBytes(surfaceID: "surface-1")) == "welcome\r\n$ ")
        #expect(engine.replayBytes(surfaceID: "unknown") == nil)
        #expect(engine.ownsSurface("surface-1"))
        #expect(!engine.ownsSurface("unknown"))
    }

    @Test func printableInputEchoes() {
        let engine = makeEngine()
        #expect(text(engine.inputBytes("ls", surfaceID: "surface-1")) == "ls")
        // Replay after typing restores the un-executed line.
        #expect(text(engine.replayBytes(surfaceID: "surface-1")) == "welcome\r\n$ ls")
    }

    @Test func unknownSurfaceInputIsNotHandled() {
        let engine = makeEngine()
        #expect(engine.inputBytes("ls", surfaceID: "unknown") == nil)
    }

    @Test func enterRunsCannedCommands() {
        let engine = makeEngine()
        _ = engine.inputBytes("pwd", surfaceID: "surface-1")
        let output = text(engine.inputBytes("\r", surfaceID: "surface-1"))
        #expect(output == "\r\n/Users/demo/project\r\n$ ")
    }

    @Test func lsListsFilesAndEchoPrintsArgument() {
        let engine = makeEngine()
        _ = engine.inputBytes("ls", surfaceID: "surface-1")
        let lsOutput = text(engine.inputBytes("\r", surfaceID: "surface-1"))
        #expect(lsOutput.contains("src"))
        #expect(lsOutput.contains("README.md"))

        _ = engine.inputBytes("echo release ready", surfaceID: "surface-1")
        let echoOutput = text(engine.inputBytes("\n", surfaceID: "surface-1"))
        #expect(echoOutput == "\r\nrelease ready\r\n$ ")
    }

    @Test func catPrintsFileContentsWithCRLFNormalization() {
        let engine = makeEngine()
        _ = engine.inputBytes("cat README.md\r", surfaceID: "surface-1")
        let replay = text(engine.replayBytes(surfaceID: "surface-1"))
        #expect(replay.contains("hello\r\nworld"))

        let missing = text(engine.inputBytes("cat missing.txt\r", surfaceID: "surface-1"))
        #expect(missing.contains("cat: missing.txt: No such file or directory"))
    }

    @Test func unknownCommandReportsCommandNotFound() {
        let engine = makeEngine()
        let output = text(engine.inputBytes("frobnicate\r", surfaceID: "surface-1"))
        #expect(output.contains("zsh: command not found: frobnicate"))
        #expect(output.hasSuffix("$ "))
    }

    @Test func backspaceErasesTypedCharacters() {
        let engine = makeEngine()
        _ = engine.inputBytes("pwq", surfaceID: "surface-1")
        let erase = text(engine.inputBytes("\u{7F}", surfaceID: "surface-1"))
        #expect(erase == "\u{08} \u{08}")
        _ = engine.inputBytes("d", surfaceID: "surface-1")
        let output = text(engine.inputBytes("\r", surfaceID: "surface-1"))
        #expect(output.contains("/Users/demo/project"))
    }

    @Test func backspaceOnEmptyLineEchoesNothing() {
        let engine = makeEngine()
        #expect(text(engine.inputBytes("\u{7F}", surfaceID: "surface-1")).isEmpty)
    }

    @Test func controlCAbortsTheLine() {
        let engine = makeEngine()
        _ = engine.inputBytes("pw", surfaceID: "surface-1")
        let abort = text(engine.inputBytes("\u{03}", surfaceID: "surface-1"))
        #expect(abort == "^C\r\n$ ")
        // The aborted line never executes.
        let output = text(engine.inputBytes("\r", surfaceID: "surface-1"))
        #expect(output == "\r\n$ ")
    }

    @Test func escapeSequencesAreSwallowedNotEchoed() {
        let engine = makeEngine()
        // Up arrow (CSI A), then SS3 F, then plain typing.
        let output = text(engine.inputBytes("\u{1B}[A\u{1B}OFok", surfaceID: "surface-1"))
        #expect(output == "ok")
    }

    @Test func clearCommandResetsTheScreen() {
        let engine = makeEngine()
        let output = text(engine.inputBytes("clear\r", surfaceID: "surface-1"))
        #expect(output.contains("\u{1B}[2J\u{1B}[H"))
        #expect(text(engine.replayBytes(surfaceID: "surface-1")) == "$ ")
    }

    @Test func dateUsesInjectedClock() {
        // Mid-epoch instant: the year is 2025 in every timezone.
        let engine = makeEngine(now: Date(timeIntervalSince1970: 1_756_500_000))
        let output = text(engine.inputBytes("date\r", surfaceID: "surface-1"))
        #expect(output.contains("2025"))
    }

    @Test func gitStatusAnswersRealistically() {
        let engine = makeEngine()
        let output = text(engine.inputBytes("git status\r", surfaceID: "surface-1"))
        #expect(output.contains("On branch main"))
        #expect(output.contains("working tree clean"))
    }

    @Test func historySurvivesInReplayAfterCommands() {
        let engine = makeEngine()
        _ = engine.inputBytes("pwd\r", surfaceID: "surface-1")
        let replay = text(engine.replayBytes(surfaceID: "surface-1"))
        #expect(replay.contains("welcome"))
        #expect(replay.contains("pwd"))
        #expect(replay.contains("/Users/demo/project"))
        #expect(replay.hasSuffix("$ "))
    }
}
