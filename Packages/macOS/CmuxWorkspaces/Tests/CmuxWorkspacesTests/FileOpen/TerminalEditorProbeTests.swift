import Foundation
import Testing
@testable import CmuxWorkspaces

@Suite("TerminalEditorProbe")
struct TerminalEditorProbeTests {
    @Test func parsesAnEditorWithoutArguments() throws {
        let resolved = try #require(
            TerminalEditorProbe.parse("nvim\n/opt/homebrew/bin/nvim\n/opt/homebrew/bin:/usr/bin\n")
        )

        #expect(resolved.executablePath == "/opt/homebrew/bin/nvim")
        #expect(resolved.arguments.isEmpty)
    }

    @Test func keepsEditorArgumentsSeparateFromTheExecutable() throws {
        let resolved = try #require(
            TerminalEditorProbe.parse("nvim -p\n/opt/homebrew/bin/nvim\n/opt/homebrew/bin:/usr/bin\n")
        )

        #expect(resolved.executablePath == "/opt/homebrew/bin/nvim")
        #expect(resolved.arguments == ["-p"])
        #expect(resolved.pathEnvironment == "/opt/homebrew/bin:/usr/bin")
    }

    @Test func unresolvableEditorsAreRejected() {
        #expect(TerminalEditorProbe.parse("nvim\n\n/usr/bin\n") == nil)
        #expect(TerminalEditorProbe.parse("nvim\nnot-absolute\n/usr/bin\n") == nil)
        #expect(TerminalEditorProbe.parse("nvim\n/opt/homebrew/bin/nvim\n") == nil)
        #expect(TerminalEditorProbe.parse("") == nil)
    }

    @Test func resolvedEditorSurvivesARoundTrip() throws {
        let resolved = ResolvedTerminalEditor(
            executablePath: "/opt/homebrew/bin/nvim",
            arguments: ["-p"],
            pathEnvironment: "/opt/homebrew/bin:/usr/bin"
        )

        let data = try JSONEncoder().encode(resolved)
        let decoded = try JSONDecoder().decode(ResolvedTerminalEditor.self, from: data)

        #expect(decoded == resolved)
    }

    @Test func aResolvedEditorNeedsNoShellLookup() {
        let command = TerminalEditorCommand.command(
            forOpening: URL(fileURLWithPath: "/tmp/some notes.md"),
            resolvedEditor: ResolvedTerminalEditor(
                executablePath: "/opt/homebrew/bin/nvim",
                arguments: ["-p"],
                pathEnvironment: "/opt/homebrew/bin:/usr/bin"
            )
        )

        #expect(command == "'/opt/homebrew/bin/nvim' '-p' '/tmp/some notes.md'")
        #expect(
            !command.hasPrefix("exec "),
            "Ghostty prepends `exec -l`, so a leading exec would run a program named exec"
        )
        #expect(!command.contains("$VISUAL"))
        #expect(!command.contains("$EDITOR"))
    }
}
