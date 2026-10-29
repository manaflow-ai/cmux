import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextSettings
import CmuxNextWakeups
import Observation

extension BrowserLinkClickMapping {
    /// Pure: cmux.json `browser.links.*` as the browser module's value (1:1).
    init(_ setting: BrowserLinkClickSetting) {
        func action(_ value: BrowserLinkClickSetting.Action) -> BrowserLinkAction {
            switch value {
            case .currentTab: .currentTab
            case .backgroundTab: .backgroundTab
            case .foregroundTab: .foregroundTab
            case .linkPlacement: .linkPlacement
            case .newWindow: .newWindow
            case .download: .download
            }
        }
        self.init(cmdClick: action(setting.cmdClick), cmdShiftClick: action(setting.cmdShiftClick), shiftClick: action(setting.shiftClick),
                  optionClick: action(setting.optionClick), middleClick: action(setting.middleClick))
    }
}

/// Both engines follow every loaded snapshot's `browser.links.*`. Chromium's engine gets the current values when
/// it is built and each change after that (``ChromiumEngineSlot/whenBuilt(_:)``): following never builds it.
@MainActor
enum BrowserLinkClickPreference {
    /// Starts following; the caller keeps the returned followers for as long as the engines follow (the app's life).
    static func follow(_ settings: SettingsController, webKit: WebKitEngine, chromium: ChromiumEngineSlot,
                       on mainWork: MainWorkScheduler) -> [AnyObject] {
        chromium.whenBuilt { [weak settings] cef in
            cef.builtInAdBlocker = { [weak settings] in settings?.snapshot.browserBuiltInAdBlocker ?? true }  // browser.builtInAdBlocker, read at Chromium start
            cef.builtInAdBlockerChosen = { [weak settings] in settings?.snapshot.browserBuiltInAdBlockerChosen ?? false }
            if let settings { cef.linkClicks = BrowserLinkClickMapping(settings.snapshot.browserLinkClicks) }
        }
        // `background`: the mapping is read at the next click; nothing on screen waits for it.
        let links = ServiceObservation(.background, owner: "BrowserLinkClickPreference", on: mainWork) {
            settings.snapshot.browserLinkClicks
        } apply: { [weak webKit, weak chromium] setting in
            let mapping = BrowserLinkClickMapping(setting)
            webKit?.linkClicks = mapping
            chromium?.built?.linkClicks = mapping
        }
        // Chrome enterprise policies follow from here too: AppDelegate, which starts the followers, is at its line budget.
        return [links as AnyObject] + BrowserManagedPolicyPreference.follow(settings, webKit: webKit, chromium: chromium, on: mainWork)
    }
}
