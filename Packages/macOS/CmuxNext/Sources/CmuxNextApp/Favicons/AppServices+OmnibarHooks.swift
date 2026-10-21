import AppKit
import CmuxNextBookmarks
import CmuxNextBrowser
import CmuxNextSettings
import Foundation

/// The address bar's App hooks (Chrome parity, u2573): its right-click
/// menu's "Always Show Full URLs" and "Manage Search Engines…", and site
/// icons in its suggestion rows.
extension AppServices {
    func installOmnibarHooks(on entry: BrowserEntry) {
        let bar = entry.chrome.addressBar
        let display = bar.suggestionEngine.display
        display.setShowsFullURLs = { [weak self] full in
            guard let settings = self?.settings else { return }
            // task-owner: one settings write; ends when it lands (the snapshot brings it back to every bar).
            Task { @MainActor in
                do { try await settings.setSetting(at: BrowserOmnibarSetting.showFullURLsPath, to: .bool(full), by: .user) } catch {
                    NSSound.beep()
                }
            }
        }
        display.manageSearchEngines = { [weak self] in
            try? self?.settingsWindow.show(section: .browser, setting: BrowserOmnibarSetting.searchEnginePath.joined(separator: "."))
        }
        // The icon an open tab of the site shows, else the site's /favicon.ico, fetched as this tab
        // fetches icons (its profile; a Chromium tab through its own request context).
        bar.rowFavicon = { [weak self, weak tab = entry.tab] url in
            guard let self, let tab, let origin = BookmarkURL.faviconKey(for: url),
                  let address = URL(string: siteFaviconAddress(origin: origin)) else { return nil }
            return await tab.fetchFavicon(address)
        }
    }
}
