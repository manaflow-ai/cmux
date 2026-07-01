import Foundation
import Testing
@testable import CmuxWorkspaces
import CmuxSettings
import CmuxTestSupport

@MainActor
private final class RecordingSystemOpener: SystemFileOpening {
    private(set) var openedURLs: [URL] = []
    func openWithSystemDefault(_ url: URL) { openedURLs.append(url) }
}

private struct FixedEditor: PreferredEditorReading {
    var resolvedCommand: String?
}

@Suite("PreferredEditorService line references")
@MainActor
struct PreferredEditorLineReferenceTests {
    private func makeScratchDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-file-open-line-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func fragmentURL(for fileURL: URL, fragment: String) throws -> URL {
        var components = try #require(URLComponents(url: fileURL, resolvingAgainstBaseURL: false))
        components.fragment = fragment
        return try #require(components.url)
    }

    /// Names the editor script `code` so it is recognized as a VS Code-family
    /// goto editor, writes each received argument to a marker, and returns it.
    private func makeCapturingEditor(named name: String, in scratch: URL) throws -> (command: String, marker: URL) {
        let marker = scratch.appendingPathComponent("args.txt")
        let script = scratch.appendingPathComponent(name)
        try #"""
        #!/bin/sh
        : > '\#(marker.path)'
        for arg in "$@"; do
          printf '%s\n' "$arg" >> '\#(marker.path)'
        done
        """#.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return (script.path, marker)
    }

    private func waitForMarker(_ marker: URL) async throws -> String {
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: marker.path) {
            try await Task.sleep(for: .milliseconds(25))
        }
        // The marker is created empty then appended to; give the append a beat.
        for _ in 0..<200 {
            let contents = (try? String(contentsOf: marker, encoding: .utf8)) ?? ""
            if !contents.isEmpty { return contents }
            try await Task.sleep(for: .milliseconds(25))
        }
        return (try? String(contentsOf: marker, encoding: .utf8)) ?? ""
    }

    @Test func gotoEditorReceivesLineAndColumnAndGotoFlag() async throws {
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let sourceFile = scratch.appendingPathComponent("main.swift")
        try "let x = 1\n".write(to: sourceFile, atomically: true, encoding: .utf8)
        let editor = try makeCapturingEditor(named: "code", in: scratch)

        let service = PreferredEditorService(
            editor: FixedEditor(resolvedCommand: editor.command),
            capture: UITestCaptureSink(environment: [:]),
            systemOpener: RecordingSystemOpener()
        )

        service.open(try fragmentURL(for: sourceFile, fragment: "L42:5"))

        let received = try await waitForMarker(editor.marker)
        let lines = received.split(separator: "\n").map(String.init)
        #expect(lines.contains("-g"))
        #expect(lines.contains("\(sourceFile.path):42:5"))
    }
}
