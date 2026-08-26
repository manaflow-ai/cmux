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

    @Test("missing identifier format value is reported")
    func rejectsMissingIDFormatValue() {
        #expect(throws: CmuxCLIArgumentParser.ParseError.missingIDFormatValue) {
            _ = try parser.parse(["list", "--id-format"])
        }
    }
}
