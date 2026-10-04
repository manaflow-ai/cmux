import CmuxNextBrowser
import CmuxNextSettings
import Observation

extension BrowserLinkClickMapping {
    /// Pure: cmux.json `browser.links.*` as the browser module's value (1:1).
    init(_ setting: BrowserLinkClickSetting) {
        self.init()
    }
}

/// Both engines follow every loaded snapshot's `browser.links.*`.
@MainActor
enum BrowserLinkClickPreference {
    static func follow(_ settings: SettingsController, webKit: WebKitEngine, cef: CEFEngine) {
        Task { [weak settings, weak webKit, weak cef] in
            guard let settings else { return }
            for await setting in Observations({ settings.snapshot.browserLinkClicks }) {
                let mapping = BrowserLinkClickMapping(setting)
                webKit?.linkClicks = mapping
                cef?.linkClicks = mapping
            }
        }
    }
}
