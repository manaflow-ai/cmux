import Foundation
import Testing
@testable import CmuxSidebar

@Suite("SidebarMetadataArgumentParser")
struct SidebarMetadataArgumentParserTests {
    let parser = SidebarMetadataArgumentParser()

    @Test("tokenize splits on unquoted whitespace")
    func tokenizeWhitespace() {
        #expect(parser.tokenize("  a   b\tc ") == ["a", "b", "c"])
        #expect(parser.tokenize("") == [])
        #expect(parser.tokenize("   ") == [])
    }

    @Test("tokenize groups quoted spans and interprets escapes")
    func tokenizeQuotes() {
        #expect(parser.tokenize("'a b' c") == ["a b", "c"])
        #expect(parser.tokenize("\"x\\ny\"") == ["x\ny"])
        #expect(parser.tokenize("\"a\\tb\\r\"") == ["a\tb\r"])
        #expect(parser.tokenize("\"q\\\"q\"") == ["q\"q"])
        // Unknown escape is preserved literally (backslash kept).
        #expect(parser.tokenize("\"a\\zb\"") == ["a\\zb"])
    }

    @Test("parseOptions handles --key=value, --key value, and stop marker")
    func parseOptionsBasics() {
        let r = parser.parseOptions("pos1 --a=1 --b 2 -- --c not-an-option")
        #expect(r.positional == ["pos1", "--c", "not-an-option"])
        #expect(r.options == ["a": "1", "b": "2"])
    }

    @Test("parseOptions treats trailing flag with no value as empty string")
    func parseOptionsEmptyFlag() {
        let r = parser.parseOptions("--flag")
        #expect(r.options["flag"] == "")
        let r2 = parser.parseOptions("--flag --next")
        #expect(r2.options["flag"] == "")
        #expect(r2.options["next"] == "")
    }

    @Test("parseOptionsNoStop drops -- but keeps parsing options after it")
    func parseOptionsNoStop() {
        let r = parser.parseOptionsNoStop("k v -- --a 1")
        #expect(r.positional == ["k", "v"])
        #expect(r.options == ["a": "1"])
    }

    @Test("parseMetadataFormat accepts plain, markdown, md; rejects others")
    func metadataFormat() {
        #expect(parser.parseMetadataFormat("plain") == .plain)
        #expect(parser.parseMetadataFormat("PLAIN") == .plain)
        #expect(parser.parseMetadataFormat("markdown") == .markdown)
        #expect(parser.parseMetadataFormat("md") == .markdown)
        #expect(parser.parseMetadataFormat("html") == nil)
    }

    @Test("normalizedOptionValue trims and maps empty to nil")
    func normalizedValue() {
        #expect(parser.normalizedOptionValue("  x  ") == "x")
        #expect(parser.normalizedOptionValue("   ") == nil)
        #expect(parser.normalizedOptionValue(nil) == nil)
    }

    @Test("parseMutationTabTarget maps absent/uuid/index/invalid")
    func tabTarget() {
        #expect(parser.parseMutationTabTarget(options: [:]).target == .selected)

        let uuid = UUID()
        let byUUID = parser.parseMutationTabTarget(options: ["tab": uuid.uuidString])
        #expect(byUUID.target == .workspace(uuid))
        #expect(byUUID.error == nil)

        let byIndex = parser.parseMutationTabTarget(options: ["tab": "3"])
        #expect(byIndex.target == .index(3))

        let empty = parser.parseMutationTabTarget(options: ["tab": "  "])
        #expect(empty.target == nil)
        #expect(empty.error == "ERROR: Tab not found")

        let bad = parser.parseMutationTabTarget(options: ["tab": "nope"])
        #expect(bad.target == nil)
        #expect(bad.error == "ERROR: Tab not found")

        let negative = parser.parseMutationTabTarget(options: ["tab": "-1"])
        #expect(negative.target == nil)
        #expect(negative.error == "ERROR: Tab not found")
    }

    @Test("parseOptionalPanelId honors panel, surface alias, and error shapes")
    func optionalPanelId() {
        let usage = "USAGE"
        #expect(parser.parseOptionalPanelId(options: [:], usage: usage).panelId == nil)
        #expect(parser.parseOptionalPanelId(options: [:], usage: usage).error == nil)

        let uuid = UUID()
        let byPanel = parser.parseOptionalPanelId(options: ["panel": uuid.uuidString], usage: usage)
        #expect(byPanel.panelId == uuid)

        let bySurface = parser.parseOptionalPanelId(options: ["surface": uuid.uuidString], usage: usage)
        #expect(bySurface.panelId == uuid)

        let emptyPanel = parser.parseOptionalPanelId(options: ["panel": "  "], usage: usage)
        #expect(emptyPanel.panelId == nil)
        #expect(emptyPanel.error == "ERROR: Missing panel id — usage: USAGE")

        let badPanel = parser.parseOptionalPanelId(options: ["panel": "nope"], usage: usage)
        #expect(badPanel.panelId == nil)
        #expect(badPanel.error == "ERROR: Invalid panel id 'nope'")
    }

    @Test("splitMetadataBlockArgs splits at first ' -- ' only")
    func splitBlock() {
        let none = parser.splitMetadataBlockArgs("--a 1")
        #expect(none.optionsPart == "--a 1")
        #expect(none.markdownPart == nil)

        let split = parser.splitMetadataBlockArgs("--a 1 -- body -- more")
        #expect(split.optionsPart == "--a 1")
        #expect(split.markdownPart == "body -- more")
    }
}
