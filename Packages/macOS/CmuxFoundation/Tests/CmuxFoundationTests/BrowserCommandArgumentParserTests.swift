import Testing
@testable import CmuxFoundation

@Suite("Browser command argument parser")
struct BrowserCommandArgumentParserTests {
    @Test("Parses documented flags and positionals")
    func parsesFlagsAndPositionals() throws {
        let parser = BrowserCommandArgumentParser(allowedFlags: ["--snapshot-after"])

        let result = try parser.parse(["button", "--snapshot-after"])

        #expect(result.positionals == ["button"])
        #expect(result.flags == ["--snapshot-after"])
    }

    @Test("Consumes documented value options in both forms")
    func consumesValueOptions() throws {
        let parser = BrowserCommandArgumentParser(valueOptions: ["--selector"])

        let separate = try parser.parse(["--selector", "#save", "button"])
        let joined = try parser.parse(["--selector=#save", "button"])

        #expect(separate.positionals == ["button"])
        #expect(joined.positionals == ["button"])
    }

    @Test("Preserves a positional fallback after a named option")
    func preservesMixedCookieSetValue() throws {
        let parser = BrowserCommandArgumentParser(valueOptions: ["--name"])

        let result = try parser.parse(["--name", "session", "id-token"])

        #expect(result.positionals == ["id-token"])
    }

    @Test("Preserves multiple positionals for commands that join them")
    func preservesMultiplePositionals() throws {
        let parser = BrowserCommandArgumentParser()

        let result = try parser.parse(["https://example.com/search", "two", "words"])

        #expect(result.positionals == ["https://example.com/search", "two", "words"])
    }

    @Test("Treats arguments after the terminator as positionals")
    func honorsTerminator() throws {
        let parser = BrowserCommandArgumentParser(allowedFlags: ["--snapshot-after"])

        let result = try parser.parse(["--", "--snapshot-after"])

        #expect(result.positionals == ["--snapshot-after"])
        #expect(result.flags.isEmpty)
    }

    @Test("Redacts an unknown option value")
    func redactsUnknownOptionValue() {
        let parser = BrowserCommandArgumentParser()

        #expect(throws: BrowserCommandArgumentParser.ParseError.unknownOption(name: "--token")) {
            try parser.parse(["--token=SECRET"])
        }
    }

    @Test("Allows configured empty values in joined and separate forms")
    func allowsConfiguredEmptyValues() throws {
        let parser = BrowserCommandArgumentParser(
            valueOptions: ["--value"],
            optionsAllowingEmptyValues: ["--value"]
        )

        let joined = try parser.parse(["--value="])
        let separate = try parser.parse(["--value", ""])

        #expect(joined.positionals.isEmpty)
        #expect(separate.positionals.isEmpty)
    }

    @Test("Rejects empty joined values unless explicitly allowed")
    func rejectsUnconfiguredEmptyValues() {
        let parser = BrowserCommandArgumentParser(valueOptions: ["--selector"])

        #expect(throws: BrowserCommandArgumentParser.ParseError.missingValue(option: "--selector")) {
            try parser.parse(["--selector="])
        }
    }

    @Test("Reports a missing value using only the documented option")
    func reportsMissingValue() {
        let parser = BrowserCommandArgumentParser(valueOptions: ["--selector"])

        #expect(throws: BrowserCommandArgumentParser.ParseError.missingValue(option: "--selector")) {
            try parser.parse(["--selector"])
        }
    }

    @Test("Rejects extra positionals without retaining their contents")
    func rejectsExtraPositionals() {
        #expect(throws: BrowserCommandArgumentParser.ParseError.unexpectedPositionals) {
            try BrowserCommandArgumentParser.requireNoExtraPositionals(1)
        }
    }
}
