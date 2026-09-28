import CMUXAgentLaunch
import Testing

@Suite("Codex hook script names")
struct CodexHookScriptNameTests {
    @Test("Content-addressed names round trip")
    func contentAddressedNamesRoundTrip() throws {
        let name = try #require(CodexHookScriptName(
            contents: "#!/bin/sh\ncat >/dev/null\n",
            subcommand: "stop"
        ))
        let contentID = try #require(name.contentID)

        #expect(contentID.count == 16)
        #expect(name.filename == "cmux-codex-hook-\(contentID)-stop.sh")
        #expect(try #require(CodexHookScriptName(filename: name.filename)) == name)
    }

    @Test("Content and subcommand determine the filename")
    func contentAndSubcommandDetermineFilename() throws {
        let first = try #require(CodexHookScriptName(contents: "first", subcommand: "feed/Post Tool"))
        let same = try #require(CodexHookScriptName(contents: "first", subcommand: "feed/Post Tool"))
        let changed = try #require(CodexHookScriptName(contents: "second", subcommand: "feed/Post Tool"))

        #expect(first == same)
        #expect(first != changed)
        #expect(first.subcommand == "feed-Post-Tool")
        #expect(first.filename.hasSuffix("-feed-Post-Tool.sh"))
    }

    @Test("Shell command paths round-trip shell-significant characters")
    func shellCommandPathsRoundTripShellSignificantCharacters() throws {
        let safePath = "/Users/example/.cmux/hooks/cmux-codex-hook-0123456789abcdef-stop.sh"
        #expect(CodexHookScriptName.shellCommand(forScriptPath: safePath) == safePath)

        let paths = [
            "/Users/Example Name/.cmux/hooks/cmux-codex-hook-0123456789abcdef-stop.sh",
            "/Users/Example $HOME/O'Reilly/.cmux/hooks/cmux-codex-hook-0123456789abcdef-stop.sh",
            "/Users/Example;Name/.cmux/hooks/cmux-codex-hook-0123456789abcdef-stop.sh",
            "/Users/Example/back\\slash [glob]/.cmux/hooks/cmux-codex-hook-0123456789abcdef-stop.sh",
            "/Users/Example/\"double\"/.cmux/hooks/cmux-codex-hook-0123456789abcdef-stop.sh",
            "/Users/Example/three'''quotes/.cmux/hooks/cmux-codex-hook-0123456789abcdef-stop.sh",
        ]
        for path in paths {
            let command = CodexHookScriptName.shellCommand(forScriptPath: path)
            #expect(CodexHookScriptName.scriptPath(fromShellCommand: command) == path)
            #expect(!command.contains("'''"))
        }
    }

    @Test("Shell command parser rejects malformed compound commands")
    func shellCommandParserRejectsMalformedCompoundCommands() {
        #expect(
            CodexHookScriptName.scriptPath(
                fromShellCommand: "'/Users/Example Name/.cmux/hooks/cmux-codex-hook-0123456789abcdef-stop.sh' && echo bad"
            ) == nil
        )
        #expect(
            CodexHookScriptName.scriptPath(
                fromShellCommand: "'/Users/Example Name/.cmux/hooks/cmux-codex-hook-0123456789abcdef-stop.sh'; echo bad"
            ) == nil
        )
    }

    @Test("Legacy bare paths with shell characters remain parseable for ownership")
    func legacyBarePathsWithShellCharactersRemainParseableForOwnership() {
        let paths = [
            "/Users/O'Reilly/.cmux/hooks/cmux-codex-hook-0123456789abcdef-stop.sh",
            "/Users/Example $HOME/.cmux/hooks/cmux-codex-hook-0123456789abcdef-stop.sh",
            "/Users/Example;Name/.cmux/hooks/cmux-codex-hook-0123456789abcdef-stop.sh",
        ]
        for path in paths {
            #expect(CodexHookScriptName.scriptPath(fromShellCommand: path) == nil)
            #expect(CodexHookScriptName.legacyScriptPath(fromShellCommand: path) == path)
        }
    }

    @Test(
        "Empty or separator-only subcommands are rejected",
        arguments: ["", "/", "///", "---", "___"]
    )
    func emptyOrSeparatorOnlySubcommandsAreRejected(subcommand: String) {
        let name: CodexHookScriptName? = CodexHookScriptName(
            contents: "contents",
            subcommand: subcommand
        )
        #expect(name == nil)
    }

    @Test(
        "Recognized legacy generated filenames parse",
        arguments: [
            "cmux-codex-hook-stop.sh",
            "cmux-codex-hook-persistent-stop.sh",
            "cmux-codex-hook-persistent-feed-PreToolUse.sh",
        ]
    )
    func recognizedLegacyGeneratedFilenamesParse(filename: String) throws {
        let name = try #require(CodexHookScriptName(filename: filename))
        let contentID: String? = name.contentID
        #expect(contentID == nil)
        #expect(name.filename == filename)
    }

    @Test(
        "Malformed generated filenames are rejected",
        arguments: [
            "cmux-codex-hook-0123456789abcde-stop.sh",
            "cmux-codex-hook-0123456789abcdef-.sh",
            "cmux-codex-hook-0123456789ABCDEF-stop.sh",
            "cmux-codex-hook-0123456789abcdef-stop!.sh",
            "cmux-codex-hook-unrecognized.sh",
            "prefix-cmux-codex-hook-0123456789abcdef-stop.sh",
        ]
    )
    func malformedGeneratedFilenamesAreRejected(filename: String) {
        #expect(CodexHookScriptName(filename: filename) == nil)
    }
}
