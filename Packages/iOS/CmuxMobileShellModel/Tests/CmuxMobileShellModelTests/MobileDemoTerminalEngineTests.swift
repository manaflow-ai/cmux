import Foundation
import Testing

@testable import CmuxMobileShellModel

/// The demonstration terminal engine is a deterministic local PTY simulacrum:
/// canned history replays on mount, typed characters echo immediately, and
/// Enter runs the engine's filesystem commands or the showcase catalog.
/// These tests pin the line discipline (echo, backspace, Ctrl-C, escape
/// filtering), the cd/ls/pwd/cat composition over the fake project tree, and
/// the replay consistency the terminal view relies on across remounts.
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
                    workingDirectory: "/Users/demo/project",
                    displayDirectory: "~/project",
                    fileSystem: MobileDemoDirectory([
                        .directory(name: "src", MobileDemoDirectory([
                            .directory(name: "webhooks", MobileDemoDirectory([
                                .file(name: "deliver.ts", contents: "export const deliver = ..."),
                            ])),
                            .file(name: "server.ts", contents: "listen(router)"),
                        ])),
                        .directory(name: "tests", MobileDemoDirectory([
                            .file(name: "webhooks.test.ts", contents: "test(...)"),
                        ])),
                        .file(name: "README.md", contents: "hello\nworld"),
                        .file(name: "logo.svg", contents: nil),
                    ])
                ),
            ],
            now: { now }
        )
    }

    private func text(_ data: Data?) -> String {
        String(decoding: data ?? Data(), as: UTF8.self)
    }

    /// Runs one full line through the engine and returns the echoed output.
    private func run(_ engine: MobileDemoTerminalEngine, _ line: String) -> String {
        text(engine.inputBytes(line + "\r", surfaceID: "surface-1"))
    }

    @Test func replayShowsTranscriptAndPrompt() {
        let engine = makeEngine()
        let replay = text(engine.replayBytes(surfaceID: "surface-1"))
        #expect(replay.hasPrefix("welcome\r\n"))
        #expect(replay.contains("demo@demo-mac"))
        #expect(replay.contains("~/project"))
        #expect(engine.replayBytes(surfaceID: "unknown") == nil)
        #expect(engine.ownsSurface("surface-1"))
        #expect(!engine.ownsSurface("unknown"))
    }

    @Test func printableInputEchoes() {
        let engine = makeEngine()
        #expect(text(engine.inputBytes("ls", surfaceID: "surface-1")) == "ls")
        // Replay after typing restores the un-executed line.
        #expect(text(engine.replayBytes(surfaceID: "surface-1")).hasSuffix("ls"))
    }

    @Test func unknownSurfaceInputIsNotHandled() {
        let engine = makeEngine()
        #expect(engine.inputBytes("ls", surfaceID: "unknown") == nil)
    }

    // MARK: cd / ls / pwd / cat composition

    @Test func pwdShowsTheRootWorkingDirectory() {
        let engine = makeEngine()
        #expect(run(engine, "pwd").contains("/Users/demo/project\r\n"))
    }

    @Test func cdIntoADirectoryComposesWithPwdLsAndThePrompt() {
        let engine = makeEngine()
        let cdOutput = run(engine, "cd src")
        // cd is silent; the fresh prompt reflects the new directory.
        #expect(cdOutput.contains("~/project/src"))
        #expect(run(engine, "pwd").contains("/Users/demo/project/src\r\n"))
        let lsOutput = run(engine, "ls")
        #expect(lsOutput.contains("webhooks"))
        #expect(lsOutput.contains("server.ts"))
        #expect(!lsOutput.contains("README.md"))
    }

    @Test func cdSupportsNestedPathsDotDotAndTilde() {
        let engine = makeEngine()
        _ = run(engine, "cd src/webhooks")
        #expect(run(engine, "pwd").contains("/Users/demo/project/src/webhooks\r\n"))
        #expect(run(engine, "ls").contains("deliver.ts"))

        _ = run(engine, "cd ..")
        #expect(run(engine, "pwd").contains("/Users/demo/project/src\r\n"))

        _ = run(engine, "cd ~")
        #expect(run(engine, "pwd").contains("/Users/demo/project\r\n"))

        _ = run(engine, "cd src")
        _ = run(engine, "cd")
        #expect(run(engine, "pwd").contains("/Users/demo/project\r\n"))

        // .. at the root stays at the root.
        _ = run(engine, "cd ..")
        #expect(run(engine, "pwd").contains("/Users/demo/project\r\n"))
    }

    @Test func cdIntoAMissingDirectoryFailsWithoutMovingTheSession() {
        let engine = makeEngine()
        let output = run(engine, "cd missing")
        #expect(output.contains("cd: no such file or directory: missing"))
        #expect(run(engine, "pwd").contains("/Users/demo/project\r\n"))
        // Files are not directories.
        #expect(run(engine, "cd README.md").contains("no such file or directory"))
    }

    @Test func lsListsDirectoriesAndTakesAPathArgument() {
        let engine = makeEngine()
        let rootListing = run(engine, "ls")
        #expect(rootListing.contains("src"))
        #expect(rootListing.contains("tests"))
        #expect(rootListing.contains("README.md"))

        let nestedListing = run(engine, "ls src/webhooks")
        #expect(nestedListing.contains("deliver.ts"))

        #expect(run(engine, "ls missing").contains("ls: missing: No such file or directory"))
    }

    @Test func catResolvesFilesRelativeToTheWorkingDirectory() {
        let engine = makeEngine()
        #expect(run(engine, "cat README.md").contains("hello\r\nworld"))
        #expect(run(engine, "cat src/server.ts").contains("listen(router)"))

        _ = run(engine, "cd src/webhooks")
        #expect(run(engine, "cat deliver.ts").contains("export const deliver"))

        #expect(run(engine, "cat missing.txt")
            .contains("cat: missing.txt: No such file or directory"))
        _ = run(engine, "cd ~")
        // A contents-less file reads as unreadable, not as missing.
        #expect(run(engine, "cat logo.svg").contains("Permission denied"))
    }

    // MARK: Showcase catalog commands

    @Test func echoPrintsItsArgument() {
        let engine = makeEngine()
        // The typed line echoes first, then the command output, then a prompt.
        let output = run(engine, "echo release ready")
        #expect(output.contains("\r\nrelease ready\r\n"))
        #expect(output.hasSuffix("% "))
    }

    @Test func unknownCommandReportsCommandNotFound() {
        let engine = makeEngine()
        let output = run(engine, "frobnicate")
        #expect(output.contains("zsh: command not found: frobnicate"))
        #expect(output.hasSuffix("% "))
    }

    @Test func dateUsesInjectedClock() {
        // Mid-epoch instant: the year is 2025 in every timezone.
        let engine = makeEngine(now: Date(timeIntervalSince1970: 1_756_500_000))
        #expect(run(engine, "date").contains("2025"))
    }

    @Test func gitStatusAnswersRealistically() {
        let engine = makeEngine()
        let output = run(engine, "git status")
        #expect(output.contains("On branch main"))
        #expect(output.contains("working tree clean"))
    }

    @Test func showcaseCatalogIsTheSingleExtensionPoint() {
        // Engine-owned session commands stay out of the shared table; the
        // reviewer-facing showcase commands all live in it.
        for sessionCommand in ["cd", "ls", "pwd", "cat", "clear"] {
            #expect(MobileDemoCommandCatalog.responders[sessionCommand] == nil)
        }
        for showcaseCommand in ["echo", "git", "date", "whoami", "help"] {
            #expect(MobileDemoCommandCatalog.responders[showcaseCommand] != nil)
        }
    }

    // MARK: Line discipline

    @Test func backspaceErasesTypedCharacters() {
        let engine = makeEngine()
        _ = engine.inputBytes("pwq", surfaceID: "surface-1")
        let erase = text(engine.inputBytes("\u{7F}", surfaceID: "surface-1"))
        #expect(erase == "\u{08} \u{08}")
        _ = engine.inputBytes("d", surfaceID: "surface-1")
        #expect(text(engine.inputBytes("\r", surfaceID: "surface-1"))
            .contains("/Users/demo/project"))
    }

    @Test func backspaceOnEmptyLineEchoesNothing() {
        let engine = makeEngine()
        #expect(text(engine.inputBytes("\u{7F}", surfaceID: "surface-1")).isEmpty)
    }

    @Test func controlCAbortsTheLine() {
        let engine = makeEngine()
        _ = engine.inputBytes("pw", surfaceID: "surface-1")
        let abort = text(engine.inputBytes("\u{03}", surfaceID: "surface-1"))
        #expect(abort.hasPrefix("^C\r\n"))
        // The aborted line never executes.
        let output = text(engine.inputBytes("\r", surfaceID: "surface-1"))
        #expect(!output.contains("command not found"))
    }

    @Test func escapeSequencesAreSwallowedNotEchoed() {
        let engine = makeEngine()
        // Up arrow (CSI A), then SS3 F, then plain typing.
        let output = text(engine.inputBytes("\u{1B}[A\u{1B}OFok", surfaceID: "surface-1"))
        #expect(output == "ok")
    }

    @Test func clearCommandResetsTheScreen() {
        let engine = makeEngine()
        let output = run(engine, "clear")
        #expect(output.contains("\u{1B}[2J\u{1B}[H"))
        let replay = text(engine.replayBytes(surfaceID: "surface-1"))
        #expect(!replay.contains("welcome"))
        #expect(replay.hasSuffix("% "))
    }

    @Test func historySurvivesInReplayAfterCommands() {
        let engine = makeEngine()
        _ = run(engine, "cd src")
        _ = run(engine, "pwd")
        let replay = text(engine.replayBytes(surfaceID: "surface-1"))
        #expect(replay.contains("welcome"))
        #expect(replay.contains("cd src"))
        #expect(replay.contains("/Users/demo/project/src"))
        // The live prompt reflects the current directory after a remount.
        #expect(replay.hasSuffix("% "))
        #expect(replay.contains("~/project/src"))
    }
}
