import CmuxNextSettings
import Foundation
import Testing

/// cmux.json `palette.aliases` and `palette.pins` (cx-9ce.43) as the palette reads them: each alias
/// names one command, pins keep the user's order, and bad entries are dropped.
struct PaletteRankingSettingTests {
    @Test func readsAliasesAndPinsFromCmuxJSON() throws {
        let json = """
        {
          "palette": {
            "aliases": { "vs": "splitRight", "VSplit": "splitRight", "nt": "newTab.default", "bad": 3, "": "closeTab" },
            "pins": ["newTab.default", "splitRight", "newTab.default", "", 7]
          }
        }
        """
        let setting = PaletteRankingSetting(try JSONValue.parse(Data(json.utf8)))
        #expect(setting.aliases.mapValues { Set($0) } == ["splitRight": ["vs", "VSplit"], "newTab.default": ["nt"]])
        #expect(setting.pins == ["newTab.default", "splitRight"])
        #expect(PaletteRankingSetting(.object([:])) == PaletteRankingSetting(.object(["palette": .string("x")])))
    }
}
