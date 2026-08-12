import Foundation
import Testing
@testable import CmuxWorkspaces

@Suite("TerminalEditorCommand")
struct TerminalEditorCommandTests {
    @Test func posixShellsResolveTheEditorAtRuntime() {
        let command = TerminalEditorCommand.command(
            forOpening: URL(fileURLWithPath: "/tmp/notes.md"),
            userShell: "/bin/zsh"
        )

        #expect(command == "exec ${VISUAL:-${EDITOR:-vi}} '/tmp/notes.md'")
    }

    @Test func anUnknownShellUsesPosixSyntax() {
        let command = TerminalEditorCommand.command(
            forOpening: URL(fileURLWithPath: "/tmp/notes.md"),
            userShell: nil
        )

        #expect(command.hasPrefix("exec ${VISUAL:-${EDITOR:-vi}}"))
    }

    @Test func commandQuotesThePath() {
        let command = TerminalEditorCommand.command(
            forOpening: URL(fileURLWithPath: "/tmp/some notes.md"),
            userShell: "/bin/bash"
        )

        #expect(command.hasSuffix("'/tmp/some notes.md'"))
    }

    @Test func commandEscapesEmbeddedSingleQuotes() {
        let command = TerminalEditorCommand.command(
            forOpening: URL(fileURLWithPath: "/tmp/it's here.md"),
            userShell: "/bin/zsh"
        )

        #expect(command.hasSuffix("'/tmp/it'\\''s here.md'"))
    }

    @Test func execReplacesTheShellSoTheSurfaceClosesWithTheEditor() {
        let command = TerminalEditorCommand.command(
            forOpening: URL(fileURLWithPath: "/tmp/notes.md"),
            userShell: "/bin/zsh"
        )

        #expect(command.hasPrefix("exec "))
    }

    @Test func fishUsesItsOwnConditionalSyntax() {
        let command = TerminalEditorCommand.command(
            forOpening: URL(fileURLWithPath: "/tmp/notes.md"),
            userShell: "/opt/homebrew/bin/fish"
        )

        #expect(command.contains("set -l cmux_editor $VISUAL"))
        #expect(command.contains("or set cmux_editor $EDITOR"))
        #expect(command.contains("or set cmux_editor vi"))
        #expect(command.contains("exec $cmux_editor '/tmp/notes.md'"))
        #expect(!command.contains("${VISUAL"))
    }

    @Test func theFallbackEditorIsPosixGuaranteed() {
        #expect(TerminalEditorCommand.fallbackEditor == "vi")
    }
}
