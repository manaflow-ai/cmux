import CmuxNextSettings
import Testing

/// User 2026-10-20: "cmd click on links needs to always open in the right". In a browser page,
/// Command-click defaults to `linkPlacement` (a tab in the pane right of the page, or a new split
/// there), the same place a terminal's or a chat's Command-click lands. Every other click keeps
/// Chrome's default, and `linkPlacement` is a choice for every modified click.
struct BrowserCmdClickLinkPlacementSettingTests {
    private func links(_ members: [String: JSONValue]?) -> CmuxConfigSnapshot {
        let root: JSONValue = members.map { .object(["browser": .object(["links": .object($0)])]) } ?? .object([:])
        return CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
    }

    @Test func commandClickDefaultsToThePaneOnTheRight() {
        let setting = links(nil).browserLinkClicks
        #expect(setting.cmdClick.rawValue == "linkPlacement", "Command-click still opens a background tab in the page's own pane")
        #expect(setting.cmdShiftClick.rawValue == "foregroundTab")
        #expect(setting.shiftClick.rawValue == "newWindow")
        #expect(setting.optionClick.rawValue == "download")
        #expect(setting.middleClick.rawValue == "backgroundTab")
    }

    @Test func linkPlacementIsAValidChoiceAndChromesDefaultStaysAvailable() {
        let snapshot = links(["shiftClick": .string("linkPlacement"), "cmdClick": .string("backgroundTab")])
        #expect(snapshot.browserLinkClicks.shiftClick.rawValue == "linkPlacement")
        #expect(snapshot.browserLinkClicks.cmdClick.rawValue == "backgroundTab")
        #expect(!snapshot.diagnostics.contains { $0.path.hasPrefix("browser.links") })
    }
}
