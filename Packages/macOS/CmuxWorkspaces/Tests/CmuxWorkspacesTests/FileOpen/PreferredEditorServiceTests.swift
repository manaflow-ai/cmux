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

    @Test func genericConfiguredCommandReceivesPlainPathForSourceLocation() async throws {
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let marker = scratch.appendingPathComponent("received-location.txt")
        let script = scratch.appendingPathComponent("location-editor.sh")
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
        let fileURL = URL(fileURLWithPath: "/tmp/source file.swift")

        service.open(fileURL, line: 42, column: 7)

        for _ in 0..<200 where !FileManager.default.fileExists(atPath: marker.path) {
            try await Task.sleep(for: .milliseconds(25))
        }
        let received = try String(contentsOf: marker, encoding: .utf8)
        #expect(received == "/tmp/source file.swift")
        #expect(opener.openedURLs.isEmpty)
    }

    @Test func visualStudioCodeCommandUsesGotoForSourceLocation() {
        let command = PreferredEditorLaunchCommand(command: "code -w")

        #expect(
            command.shellCommand(
                url: URL(fileURLWithPath: "/tmp/source file.swift"),
                line: 42,
                column: 7
            ) == "code -w '--goto' '/tmp/source file.swift:42:7'"
        )
    }

    @Test(arguments: [
        "env -u ELECTRON_RUN_AS_NODE code -w",
        #"/Applications/Visual\ Studio\ Code.app/Contents/Resources/app/bin/code -w"#,
        "\"/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code\" -w",
    ])
    func shellWrappedVisualStudioCodeCommandsSupportSourceLocations(command: String) {
        #expect(PreferredEditorLaunchCommand(command: command).supportsSourceLocation)
    }

    @Test(arguments: [
        "code -w && osascript -e 'display dialog 1'",
        "code -w | tee /tmp/editor.log",
        "code -w; osascript -e 'display dialog 1'",
        "code -w > /tmp/editor.log",
        "code $(printf '%s' -w)",
        "code --",
    ])
    func compoundCommandsDoNotClaimSourceLocationSupport(command: String) {
        let launchCommand = PreferredEditorLaunchCommand(command: command)
        #expect(!launchCommand.supportsSourceLocation)
        #expect(
            !launchCommand.shellCommand(
                url: URL(fileURLWithPath: "/tmp/App.swift"),
                line: 42,
                column: 7
            ).contains("App.swift:42:7")
        )
    }

    @Test func colonLocationEditorsReceiveLocationWithoutGotoFlag() {
        let command = PreferredEditorLaunchCommand(command: "zed")

        #expect(
            command.shellCommand(
                url: URL(fileURLWithPath: "/tmp/App.swift"),
                line: 9,
                column: nil
            ) == "zed '/tmp/App.swift:9'"
        )
    }

    @Test func unknownEditorDoesNotClaimSourceLocationSupport() {
        #expect(!PreferredEditorLaunchCommand(command: "/tmp/editor.sh").supportsSourceLocation)
    }

    @Test func systemFallbackReceivesPlainFileURLForSourceLocation() {
        let opener = RecordingSystemOpener()
        let service = PreferredEditorService(
            editor: FixedEditor(resolvedCommand: nil),
            capture: UITestCaptureSink(environment: [:]),
            systemOpener: opener
        )
        let fileURL = URL(fileURLWithPath: "/tmp/source.swift")

        service.open(fileURL, line: 42, column: 7)

        #expect(opener.openedURLs == [fileURL])
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
}
