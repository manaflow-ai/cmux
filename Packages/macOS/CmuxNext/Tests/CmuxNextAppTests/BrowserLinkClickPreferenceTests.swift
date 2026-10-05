import CmuxNextBrowser
@testable import CmuxNextApp
import CmuxNextSettings
import Testing

/// The App maps cmux.json `browser.links.*` 1:1 onto the browser module's
/// `BrowserLinkClickMapping` (R123).
@Suite struct BrowserLinkClickPreferenceTests {
    @Test func defaultsAreChrome() {
        #expect(BrowserLinkClickMapping(BrowserLinkClickSetting.fallback) == .chrome)
    }

    @Test func everyKeyAndActionMapsOneToOne() {
        let actions: [(BrowserLinkClickSetting.Action, BrowserLinkAction)] = [
            (.currentTab, .currentTab), (.backgroundTab, .backgroundTab), (.foregroundTab, .foregroundTab),
            (.newWindow, .newWindow), (.download, .download),
        ]
        #expect(actions.count == BrowserLinkClickSetting.Action.allCases.count)
        for (value, expected) in actions {
            var setting = BrowserLinkClickSetting()
            setting.cmdClick = value
            setting.cmdShiftClick = value
            setting.shiftClick = value
            setting.optionClick = value
            setting.middleClick = value
            #expect(BrowserLinkClickMapping(setting) == BrowserLinkClickMapping(
                cmdClick: expected, cmdShiftClick: expected, shiftClick: expected, optionClick: expected, middleClick: expected
            ))
        }
        var mixed = BrowserLinkClickSetting()
        mixed.shiftClick = .currentTab
        #expect(BrowserLinkClickMapping(mixed) == BrowserLinkClickMapping(shiftClick: .currentTab))
    }
}
