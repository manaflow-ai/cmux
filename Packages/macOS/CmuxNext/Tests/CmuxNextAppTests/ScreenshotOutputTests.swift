import CmuxNextActions
@testable import CmuxNextApp
import Foundation
import Testing

/// The `out` argument of `cmux window|pane|tab screenshot`: an absolute file,
/// `-` for the image inline, or a temporary file when omitted. Anything else
/// is refused with the reason before a capture starts.
@Suite struct ScreenshotOutputTests {
    private func output(_ value: ActionValue?) throws -> ScreenshotOutput {
        var invocation = ActionInvocation(origin: .cli)
        if let value { invocation.arguments["out"] = value }
        return try ScreenshotOutput(invocation)
    }

    private func parsed(_ text: String, folders: Set<String> = []) throws -> ScreenshotOutput {
        try ScreenshotOutput(out: text, isDirectory: { folders.contains($0) })
    }

    @Test func omittedWritesATemporaryFile() throws {
        #expect(try output(nil) == .temporary)
    }

    @Test func aDashAnswersInline() throws {
        #expect(try output(.string("-")) == .inline)
        #expect(try parsed(" - ") == .inline)
    }

    @Test func anAbsolutePathIsTheFile() throws {
        #expect(try parsed("/tmp/shots/window.png") == .file(URL(fileURLWithPath: "/tmp/shots/window.png")))
        #expect(try parsed("/tmp/shots/../window.png") == .file(URL(fileURLWithPath: "/tmp/window.png")))
    }

    @Test func aTildeIsTheHomeFolder() throws {
        let expected = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("shot.png")
        #expect(try parsed("~/shot.png") == .file(expected))
    }

    @Test(arguments: ["shot.png", "./shots/shot.png", "shots/"])
    func aRelativePathIsRefused(_ text: String) {
        #expect(throws: ActionFailure.self) { try parsed(text) }
    }

    @Test func aFolderIsRefused() {
        #expect(throws: ActionFailure.self) { try parsed("/tmp/shots/") }
        #expect(throws: ActionFailure.self) { try parsed("/tmp/shots", folders: ["/tmp/shots"]) }
    }

    @Test func anEmptyOrNonTextValueIsRefused() {
        #expect(throws: ActionFailure.self) { try parsed("  ") }
        // A bare `--out` with no value arrives as `true`.
        #expect(throws: ActionFailure.self) { try output(.bool(true)) }
    }

    @Test func theReasonNamesTheBadPath() throws {
        do {
            _ = try parsed("relative.png")
            Issue.record("a relative path was accepted")
        } catch let failure as ActionFailure {
            #expect(failure.message.contains("relative.png"))
        }
    }
}
