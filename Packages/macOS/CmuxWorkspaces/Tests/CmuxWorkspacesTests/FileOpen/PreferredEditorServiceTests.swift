import Foundation
import Testing
@testable import CmuxWorkspaces
import CmuxSettings
import CmuxTestSupport

@MainActor
private final class RecordingSystemOpener: SystemFileOpening {
    private(set) var openedURLs: [URL] = []
    var onOpen: (@MainActor () -> Void)?

    func openWithSystemDefault(_ url: URL) {
        openedURLs.append(url)
        onOpen?()
    }
}

private struct FixedEditor: PreferredEditorReading {
    var resolvedCommand: String?
}

@Suite("PreferredEditorService")
@MainActor
struct PreferredEditorServiceTests {
    @Test(arguments: [
        "nvim", "/opt/homebrew/bin/nvim", "env nvim", "/usr/bin/env nvim",
        "env FOO=1 nvim", "env -u TERM nvim", "FOO=1 /usr/bin/nvim",
        "env -S nvim --clean", "env -S \"nvim --clean\"", "vim --clean",
        "env --split-string='nvim --clean'", "env --split-string=\"nvim --clean\"",
        "exec nvim", "exec -a myeditor nvim", "command -- nvim",
        "nice -n 10 nvim", "sudo -u root nvim", "sudo -p prompt nvim",
        "sudo --user=root /usr/bin/env FOO=1 'nvim'"
    ])
    func terminalEditorCommandsAreDetected(command: String) {
        #expect(PreferredEditorService.isTerminalEditorCommand(command))
    }

    @Test("env -S re-tokenizes a quoted command payload")
    func envSplitStringPayloadIsTokenized() {
        #expect(PreferredEditorService.isTerminalEditorCommand("env -S \"FOO=1 nvim --clean\""))
        #expect(!PreferredEditorService.isTerminalEditorCommand("env -S \"FOO=1 code --wait\""))
    }

    @Test(arguments: [
        "code", "/Applications/Zed.app/Contents/MacOS/zed", "my-nvim-wrapper",
        "env FOO=1 code", "env -u TERM /Applications/Zed.app/Contents/MacOS/zed",
        "env --split-string='code --wait'", "exec -a nvim code", "sudo -p prompt code",
        "emacs", "'/Applications/Visual Studio Code.app/Contents/MacOS/code'"
    ])
    func graphicalEditorCommandsAreNotDetected(command: String) {
        #expect(!PreferredEditorService.isTerminalEditorCommand(command))
    }

    @Test(arguments: [
        "emacs -nw", "emacs --no-window-system", "exec emacs -nw",
        "sudo emacs --no-window-system"
    ])
    func terminalEmacsModeIsDetected(command: String) {
        #expect(PreferredEditorService.isTerminalEditorCommand(command))
    }

    @Test(arguments: [
        "'/Applications/Neovim.app/Contents/MacOS/nvim'",
        "exec '/opt/tools/nvim' --clean"
    ])
    func quotedExecutablePathsAreParsed(command: String) {
        #expect(PreferredEditorService.isTerminalEditorCommand(command))
    }

    private func makeScratchDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-file-open-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func configuredCaptureInterceptsTheOpen() throws {
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let captureFile = scratch.appendingPathComponent("opens.txt")
        let opener = RecordingSystemOpener()
        let service = PreferredEditorService(
            editor: FixedEditor(resolvedCommand: "/usr/bin/false"),
            capture: UITestCaptureSink(
                environment: ["CMUX_UI_TEST_CAPTURE_OPEN_PATH": captureFile.path]
            ),
            systemOpener: opener
        )

        service.open(URL(fileURLWithPath: "/tmp/captured file.md"))

        let contents = try String(contentsOf: captureFile, encoding: .utf8)
        #expect(contents == "/tmp/captured file.md\n")
        #expect(opener.openedURLs.isEmpty)
    }

    @Test func noConfiguredCommandFallsBackToSystemOpen() {
        let opener = RecordingSystemOpener()
        let service = PreferredEditorService(
            editor: FixedEditor(resolvedCommand: nil),
            capture: UITestCaptureSink(environment: [:]),
            systemOpener: opener
        )
        let url = URL(fileURLWithPath: "/tmp/plain.txt")

        service.open(url)

        #expect(opener.openedURLs == [url])
    }

    @Test func terminalEditorFallsBackWithoutLaunchingTheCommand() async throws {
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let marker = scratch.appendingPathComponent("launched.txt")
        let editor = scratch.appendingPathComponent("nvim")
        try #"""
        #!/bin/sh
        touch '\#(marker.path)'
        exit 1
        """#.write(to: editor, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: editor.path
        )

        let opener = RecordingSystemOpener()
        let service = PreferredEditorService(
            editor: FixedEditor(resolvedCommand: editor.path),
            capture: UITestCaptureSink(environment: [:]),
            systemOpener: opener
        )
        let url = URL(fileURLWithPath: "/tmp/plain.txt")

        await withCheckedContinuation { continuation in
            opener.onOpen = { continuation.resume() }
            service.open(url)
        }

        #expect(opener.openedURLs == [url])
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func wrappedTerminalEditorsFallBackWithoutLaunchingTheCommand() async throws {
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let marker = scratch.appendingPathComponent("launched.txt")
        let editor = scratch.appendingPathComponent("nvim")
        let env = scratch.appendingPathComponent("env")
        try #"""
        #!/bin/sh
        touch '\#(marker.path)'
        exit 1
        """#.write(to: editor, atomically: true, encoding: .utf8)
        try FileManager.default.copyItem(at: editor, to: env)
        for executable in [editor, env] {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: executable.path
            )
        }

        let commands = [
            "exec -a myeditor \(editor.path)",
            "\(env.path) --split-string='\(editor.path) --clean'"
        ]
        let opener = RecordingSystemOpener()
        let url = URL(fileURLWithPath: "/tmp/plain.txt")

        for command in commands {
            let service = PreferredEditorService(
                editor: FixedEditor(resolvedCommand: command),
                capture: UITestCaptureSink(environment: [:]),
                systemOpener: opener
            )
            await withCheckedContinuation { continuation in
                opener.onOpen = { continuation.resume() }
                service.open(url)
            }
            opener.onOpen = nil
            #expect(!FileManager.default.fileExists(atPath: marker.path))
            try? FileManager.default.removeItem(at: marker)
        }

        #expect(opener.openedURLs == Array(repeating: url, count: commands.count))
    }

    @Test func configuredCommandReceivesTheQuotedPathAsItsArgument() async throws {
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let marker = scratch.appendingPathComponent("received.txt")
        let script = scratch.appendingPathComponent("editor.sh")
        try #"""
        #!/bin/sh
        printf %s "$1" > '\#(marker.path)'
        """#.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: script.path
        )

        let opener = RecordingSystemOpener()
        let service = PreferredEditorService(
            editor: FixedEditor(resolvedCommand: script.path),
            capture: UITestCaptureSink(environment: [:]),
            systemOpener: opener
        )
        // A path needing quoting: spaces and an embedded single quote.
        let awkwardPath = "/tmp/it's a file.md"

        service.open(URL(fileURLWithPath: awkwardPath))

        // Bounded wait for the spawned editor script to write the marker;
        // the script signals completion by creating the file.
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: marker.path) {
            try await Task.sleep(for: .milliseconds(25))
        }
        let received = try String(contentsOf: marker, encoding: .utf8)
        #expect(received == awkwardPath)
        #expect(opener.openedURLs.isEmpty)
    }

    @Test func configuredCommandReceivesLineAndColumnLocation() async throws {
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let marker = scratch.appendingPathComponent("received.txt")
        let script = scratch.appendingPathComponent("editor.sh")
        try #"""
        #!/bin/sh
        printf %s "$1" > '\#(marker.path)'
        """#.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: script.path
        )

        let service = PreferredEditorService(
            editor: FixedEditor(resolvedCommand: script.path),
            capture: UITestCaptureSink(environment: [:]),
            systemOpener: RecordingSystemOpener()
        )
        service.open(URL(fileURLWithPath: "/tmp/main.swift"), line: 42, column: 5)

        for _ in 0..<200 where !FileManager.default.fileExists(atPath: marker.path) {
            try await Task.sleep(for: .milliseconds(25))
        }
        let received = try String(contentsOf: marker, encoding: .utf8)
        #expect(received == "/tmp/main.swift:42:5")
    }

    @Test func failingCommandFallsBackToSystemOpen() async {
        let opener = RecordingSystemOpener()
        let service = PreferredEditorService(
            editor: FixedEditor(resolvedCommand: "/usr/bin/false"),
            capture: UITestCaptureSink(environment: [:]),
            systemOpener: opener
        )
        let url = URL(fileURLWithPath: "/tmp/should-fall-back.txt")

        await withCheckedContinuation { continuation in
            opener.onOpen = { continuation.resume() }
            service.open(url)
        }

        #expect(opener.openedURLs == [url])
    }

    @Test func launchEnvironmentAppendsStandardCLIDirectoriesToGUIPath() {
        let environment = PreferredEditorService.launchEnvironment(
            base: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        )
        let entries = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        #expect(entries.contains("/usr/local/bin"))
        #expect(entries.contains("/opt/homebrew/bin"))
        // Inherited entries keep precedence over the appended directories.
        #expect(entries.first == "/usr/bin")
    }

    @Test func launchEnvironmentDoesNotDuplicateDirectoriesAlreadyOnPath() {
        let loginShellPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        let environment = PreferredEditorService.launchEnvironment(
            base: ["PATH": loginShellPath]
        )
        #expect(environment["PATH"] == loginShellPath)
    }

    @Test func launchEnvironmentPreservesOtherVariables() {
        let environment = PreferredEditorService.launchEnvironment(
            base: ["PATH": "/usr/bin:/bin", "HOME": "/Users/example", "LANG": "en_US.UTF-8"]
        )
        #expect(environment["HOME"] == "/Users/example")
        #expect(environment["LANG"] == "en_US.UTF-8")
    }

    @Test func launchEnvironmentProvidesUsablePathWhenBasePathMissingOrEmpty() {
        for base in [[String: String](), ["PATH": ""], ["PATH": "   "]] {
            let environment = PreferredEditorService.launchEnvironment(base: base)
            let entries = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
            #expect(
                entries.contains("/usr/bin") && entries.contains("/usr/local/bin"),
                "base \(base) should still yield a usable PATH, got \(entries)"
            )
        }
    }
}
