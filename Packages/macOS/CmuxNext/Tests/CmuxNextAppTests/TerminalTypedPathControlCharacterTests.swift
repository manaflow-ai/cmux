import CmuxNextOnboarding
@testable import CmuxNextTerminal
import Foundation
import Testing

/// A path cmux types into a shell must hold no control character (Ghostty 1.4.0, 0c234a04d
/// "macos: refuse to execute files with control characters in the path"). Opening a script with
/// cmux types its shell-quoted path into a new terminal; a file named `/tmp/Foo<Ctrl-U>ls<CR>`
/// shows as `/tmp/Fools`, but typed, Ctrl-U erases the quoted path and CR runs `ls`. Quoting
/// cannot make such bytes safe for typed input in every shell, so these paths are refused: U+0000
/// to U+001F, U+007F and U+0080 to U+009F. A dropped or pasted file's path follows the same rule.
@MainActor @Suite("Typed path control characters")
struct TerminalTypedPathControlCharacterTests {
    static let hostile = ["/tmp/Foo\u{15}ls\r", "/tmp/a\u{01}b", "/tmp/a\u{1B}[201~b", "/tmp/a\u{7F}b",
                          "/tmp/a\u{85}b", "/tmp/a\u{9B}b", "/tmp/x\nrm -rf ~"]

    @Test(arguments: hostile)
    func openingAScriptWhosePathHasAControlCharacterTypesNothing(_ path: String) {
        let executable = ExternalOpenRouter(isDirectory: { _ in false }, isExecutable: { _ in true })
        let plain = ExternalOpenRouter(isDirectory: { _ in false }, isExecutable: { _ in false })
        #expect(executable.route(URL(fileURLWithPath: path)) == .unsupported, "an executable was typed")
        #expect(executable.route(URL(fileURLWithPath: path + ".command")) == .unsupported, "a .command was typed")
        #expect(plain.route(URL(fileURLWithPath: path + ".sh")) == .unsupported, "`sh <path>` was typed")
    }

    @Test(arguments: hostile)
    func droppingOrPastingAFileWhosePathHasAControlCharacterPastesNothing(_ path: String) {
        let contents = TerminalPasteboardContents(fileURLs: [URL(fileURLWithPath: "/tmp/ok.txt"), URL(fileURLWithPath: path)])
        #expect(TerminalPasteboard.pasteText(from: contents) == nil)
    }

    @Test func plainPathsStillOpenAndPaste() {
        let executable = ExternalOpenRouter(isDirectory: { _ in false }, isExecutable: { _ in true })
        #expect(executable.route(URL(fileURLWithPath: "/tmp/run me.command"))
            == .terminal(cwd: "/tmp", command: "'/tmp/run me.command'"))
        #expect(executable.route(URL(fileURLWithPath: "/tmp/it's")) == .terminal(cwd: "/tmp", command: #"'/tmp/it'\''s'"#))
        let contents = TerminalPasteboardContents(fileURLs: [URL(fileURLWithPath: "/tmp/a b.txt")])
        #expect(TerminalPasteboard.pasteText(from: contents) == "/tmp/a\\ b.txt")
    }
}
