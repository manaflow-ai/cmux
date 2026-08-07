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
