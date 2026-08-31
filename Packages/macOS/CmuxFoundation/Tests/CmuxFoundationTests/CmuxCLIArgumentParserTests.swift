import Testing
@testable import CmuxFoundation

@Suite("cmux CLI argument parser")
struct CmuxCLIArgumentParserTests {
    private let parser = CmuxCLIArgumentParser()

    @Test("presentation flags after a subcommand are extracted")
    func extractsPostSubcommandJSON() throws {
        let result = try parser.parse(["list", "--json", "--id-format", "both"])
        #expect(result.jsonOutput)
        #expect(result.idFormat == "both")
        #expect(result.remaining == ["list"])
    }

    @Test("command option values that look like flags are preserved")
    func preservesOptionValues() throws {
        let result = try parser.parse(["run", "--command", "--json", "--json"])
        #expect(result.jsonOutput)
        #expect(result.remaining == ["run", "--command", "--json"])
    }

    @Test("terminator stops presentation parsing")
    func honorsTerminator() throws {
        let result = try parser.parse(["run", "--", "--json"])
        #expect(!result.jsonOutput)
        #expect(result.remaining == ["run", "--", "--json"])
    }

    @Test("send treats atomic after the terminator as prompt text")
    func sendHonorsAtomicTerminator() throws {
        let result = try parser.parse(
            ["--", "literal --atomic", "--json"],
            command: "send"
        )
        #expect(!result.atomic)
        #expect(!result.jsonOutput)
        #expect(result.remaining == ["--", "literal --atomic", "--json"])
    }

    @Test("send does not let the hooks agent option swallow presentation flags")
    func sendPreservesLegacyAgentTextAndExtractsJSON() throws {
        let result = try parser.parse(
            ["--agent", "--json", "draft"],
            command: "send"
        )
        #expect(result.jsonOutput)
        #expect(!result.atomic)
        #expect(result.remaining == ["--agent", "draft"])
    }

    @Test("send keeps a paired legacy agent atomic token literal")
    func sendPreservesPairedAtomicText() throws {
        let result = try parser.parse(
            ["--agent", "--atomic", "draft"],
            command: "send"
        )
        #expect(!result.atomic)
        #expect(result.remaining == ["--agent", "--atomic", "draft"])
    }

    @Test("send extracts only a standalone atomic flag")
    func sendExtractsStandaloneAtomic() throws {
        let result = try parser.parse(
            ["--workspace", "workspace:1", "--atomic", "draft"],
            command: "send"
        )
        #expect(result.atomic)
        #expect(result.remaining == ["--workspace", "workspace:1", "draft"])
    }

    @Test("missing identifier format value is reported")
    func rejectsMissingIDFormatValue() {
        #expect(throws: CmuxCLIArgumentParser.ParseError.missingIDFormatValue) {
            _ = try parser.parse(["list", "--id-format"])
        }
    }
}
