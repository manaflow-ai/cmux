import CMUXAgentLaunch
import Testing

@Suite("Codex hook script names")
struct CodexHookScriptNameTests {
    @Test("Content-addressed names round trip")
    func contentAddressedNamesRoundTrip() throws {
        let name = CodexHookScriptName(
            contents: "#!/bin/sh\ncat >/dev/null\n",
            subcommand: "stop"
        )

        #expect(name.contentID.count == 16)
        #expect(name.filename == "cmux-codex-hook-\(name.contentID)-stop.sh")
        #expect(try #require(CodexHookScriptName(filename: name.filename)) == name)
    }

    @Test("Content and subcommand determine the filename")
    func contentAndSubcommandDetermineFilename() {
        let first = CodexHookScriptName(contents: "first", subcommand: "feed/Post Tool")
        let same = CodexHookScriptName(contents: "first", subcommand: "feed/Post Tool")
        let changed = CodexHookScriptName(contents: "second", subcommand: "feed/Post Tool")

        #expect(first == same)
        #expect(first != changed)
        #expect(first.subcommand == "feed-Post-Tool")
        #expect(first.filename.hasSuffix("-feed-Post-Tool.sh"))
    }

    @Test(
        "Malformed generated filenames are rejected",
        arguments: [
            "cmux-codex-hook-stop.sh",
            "cmux-codex-hook-0123456789abcde-stop.sh",
            "cmux-codex-hook-0123456789abcdef-.sh",
            "cmux-codex-hook-0123456789ABCDEF-stop.sh",
            "cmux-codex-hook-0123456789abcdef-stop!.sh",
            "prefix-cmux-codex-hook-0123456789abcdef-stop.sh",
        ]
    )
    func malformedGeneratedFilenamesAreRejected(filename: String) {
        #expect(CodexHookScriptName(filename: filename) == nil)
    }
}
