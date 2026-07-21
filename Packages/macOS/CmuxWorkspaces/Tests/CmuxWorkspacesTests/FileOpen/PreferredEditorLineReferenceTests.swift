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

@Suite("PreferredEditorService editor invocation")
@MainActor
struct PreferredEditorInvocationTests {
    private func fragmentURL(path: String, fragment: String?) -> URL {
        var components = URLComponents(url: URL(fileURLWithPath: path), resolvingAgainstBaseURL: false)
        components?.fragment = fragment
        return components?.url ?? URL(fileURLWithPath: path)
    }

    @Test func addsGotoFlagAndLineColumnForGotoEditor() {
        let invocation = PreferredEditorService.editorInvocation(
            forURL: fragmentURL(path: "/tmp/main.swift", fragment: "L42:5"),
            command: "code"
        )
        #expect(invocation.gotoFlag == " -g")
        #expect(invocation.argument == "/tmp/main.swift:42:5")
    }

    @Test func addsLineOnlyWhenNoColumn() {
        let invocation = PreferredEditorService.editorInvocation(
            forURL: fragmentURL(path: "/tmp/main.swift", fragment: "L42"),
            command: "cursor"
        )
        #expect(invocation.gotoFlag == " -g")
        #expect(invocation.argument == "/tmp/main.swift:42")
    }

    @Test func keepsExistingGotoFlag() {
        let invocation = PreferredEditorService.editorInvocation(
            forURL: fragmentURL(path: "/tmp/main.swift", fragment: "L42:5"),
            command: "code --goto"
        )
        #expect(invocation.gotoFlag == "")
        #expect(invocation.argument == "/tmp/main.swift:42:5")
    }

    @Test func recognizesQuotedBinaryPath() {
        let invocation = PreferredEditorService.editorInvocation(
            forURL: fragmentURL(path: "/tmp/main.swift", fragment: "L42:5"),
            command: "\"/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code\""
        )
        #expect(invocation.gotoFlag == " -g")
        #expect(invocation.argument == "/tmp/main.swift:42:5")
    }

    @Test func recognizesBackslashEscapedBinaryPath() {
        let invocation = PreferredEditorService.editorInvocation(
            forURL: fragmentURL(path: "/tmp/main.swift", fragment: "L42:5"),
            command: "/Applications/Visual\\ Studio\\ Code.app/Contents/Resources/app/bin/code --goto"
        )
        #expect(invocation.gotoFlag == "")
        #expect(invocation.argument == "/tmp/main.swift:42:5")
    }

    @Test func doesNotTreatBackslashInsideDoubleQuotesAsGotoFlag() {
        // `/bin/sh -c` preserves a literal backslash inside double quotes, so
        // `code "\--goto"` passes `\--goto` (not `--goto`) to the editor. The
        // tokenizer must match that; otherwise it wrongly reads an existing
        // `--goto` and drops the `-g` the line jump needs.
        let invocation = PreferredEditorService.editorInvocation(
            forURL: fragmentURL(path: "/tmp/main.swift", fragment: "L42:5"),
            command: "code \"\\--goto\""
        )
        #expect(invocation.gotoFlag == " -g")
        #expect(invocation.argument == "/tmp/main.swift:42:5")
    }

    @Test func recognizesGotoEditorAfterWrapperPrefix() {
        // A wrapper prefix (`arch -arm64`, `env VAR=1`, `nohup`) is a realistic
        // way to launch a VS Code-family editor, so the goto editor is not
        // necessarily the first shell word — every word is scanned.
        let invocation = PreferredEditorService.editorInvocation(
            forURL: fragmentURL(path: "/tmp/main.swift", fragment: "L42:5"),
            command: "arch -arm64 code"
        )
        #expect(invocation.gotoFlag == " -g")
        #expect(invocation.argument == "/tmp/main.swift:42:5")
    }

    @Test func leavesUnknownEditorWithBarePath() {
        let invocation = PreferredEditorService.editorInvocation(
            forURL: fragmentURL(path: "/tmp/main.swift", fragment: "L42:5"),
            command: "mate"
        )
        #expect(invocation.gotoFlag == "")
        #expect(invocation.argument == "/tmp/main.swift")
    }

    @Test func leavesBarePathWhenNoFragment() {
        let invocation = PreferredEditorService.editorInvocation(
            forURL: fragmentURL(path: "/tmp/main.swift", fragment: nil),
            command: "code"
        )
        #expect(invocation.gotoFlag == "")
        #expect(invocation.argument == "/tmp/main.swift")
    }

    @Test func rejectsFragmentMissingLMarker() {
        // The fragment contract is `L<line>[:<column>]`; a bare `#42` (e.g. a
        // document anchor, not a line reference) must not be guessed into a
        // line jump.
        let invocation = PreferredEditorService.editorInvocation(
            forURL: fragmentURL(path: "/tmp/main.swift", fragment: "42"),
            command: "code"
        )
        #expect(invocation.gotoFlag == "")
        #expect(invocation.argument == "/tmp/main.swift")
    }

    @Test func rejectsFragmentWithMalformedColumn() {
        // A colon group with a missing or non-positive-integer column is
        // malformed transport; fail closed rather than opening at a guessed
        // line-only location.
        for fragment in ["L42:", "L42:abc", "L42:0"] {
            let invocation = PreferredEditorService.editorInvocation(
                forURL: fragmentURL(path: "/tmp/main.swift", fragment: fragment),
                command: "code"
            )
            #expect(invocation.gotoFlag == "", "\(fragment) should not resolve a goto")
            #expect(invocation.argument == "/tmp/main.swift", "\(fragment) should open plain")
        }
    }
}
