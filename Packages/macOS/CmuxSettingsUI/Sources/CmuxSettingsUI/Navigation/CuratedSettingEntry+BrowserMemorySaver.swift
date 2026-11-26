import Foundation

extension Array where Element == CuratedSettingEntry {
    /// `leading`, then ``browserMemorySaverEntries``, then `trailing`. Like
    /// ``appendingDevicesEntries(to:)``, a call rather than `+` keeps the
    /// contextual type of ``cmuxDefault(catalog:)``'s large literals concrete.
    static func insertingBrowserMemorySaverEntries(
        between leading: [CuratedSettingEntry],
        and trailing: [CuratedSettingEntry]
    ) -> [CuratedSettingEntry] {
        leading + browserMemorySaverEntries + trailing
    }

    /// Search entries for the Browser Memory Saver rows in Settings > Browser
    /// (`BrowserMemorySaverSettingsRows`), in row order.
    static var browserMemorySaverEntries: [CuratedSettingEntry] {
        [
            .init(
                section: .browser,
                id: "hidden-webview-discard",
                title: String(localized: "settings.browser.hiddenWebViewDiscard", defaultValue: "Browser Memory Saver"),
                synonyms: "Browser Memory Saver browser.discardHiddenWebViews memory hidden tabs webview discard unload reclaim"
            ),
            .init(
                section: .browser,
                id: "hidden-webview-discard-mode",
                title: String(localized: "settings.browser.hiddenWebViewDiscardMode", defaultValue: "Memory Saver Mode"),
                synonyms: "Memory Saver Mode browser.hiddenWebViewDiscardMode memory budget timer hidden tabs discard unload"
            ),
            .init(
                section: .browser,
                id: "hidden-webview-memory-budget",
                title: String(localized: "settings.browser.hiddenWebViewMemoryBudget", defaultValue: "Hidden Tab Memory Budget"),
                synonyms: "Hidden Tab Memory Budget browser.hiddenWebViewMemoryBudgetMB memory budget limit megabytes mb gb hidden tabs discard"
            ),
            .init(
                section: .browser,
                id: "hidden-webview-discard-delay",
                title: String(localized: "settings.browser.hiddenWebViewDiscardDelay", defaultValue: "Memory Saver Delay"),
                synonyms: "Memory Saver Delay browser.hiddenWebViewDiscardDelaySeconds memory hidden tabs delay seconds discard unload"
            ),
            .init(
                section: .browser,
                id: "unloaded-page-auto-restore",
                title: String(localized: "settings.browser.autoRestoreUnloadedPages", defaultValue: "Restore Unloaded Pages Automatically"),
                synonyms: "Restore Unloaded Pages Automatically browser.autoRestoreUnloadedPages reload restore unloaded discarded hidden tabs placeholder"
            )
        ]
    }
}
