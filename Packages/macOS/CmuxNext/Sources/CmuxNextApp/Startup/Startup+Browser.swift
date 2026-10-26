import CmuxNextDesign
import CmuxNextPages
import CmuxNextSettings
import Foundation

// Launch calls for pages and the browser: page roots, profiles, bookmarks, history, first-party
// schemes, the browser preferences and the Chromium runtime (task 014, see Startup+Core.swift).
extension AppDelegate {
    /// The diff, file and agent activity pages' files, which live in the app bundle (markdown-viewer/webviews-app).
    func registerPageRoots() {
        PageDescriptor.registerDiffRoot()
        PageDescriptor.registerFilePageRoots()
        PageDescriptor.registerAgentActivityRoot()
    }

    /// The browser preferences that follow settings.
    func registerBrowserPreferences(services: AppServices, settings: SettingsController) {
        services.cache.browserTabs.preference.follow(settings)
        BrowserLinkClickPreference.follow(settings, webKit: services.cache.webKit, cef: services.cache.cef)
        BrowserOmnibarPreference.follow(settings, cache: services.cache)
        services.bookmarks.follow(settings)
    }

    /// The browser profiles; returns their directory, where bookmarks and history live too.
    func registerBrowserProfiles(services: AppServices) -> URL {
        let profilesDirectory = BrowserProfileService.defaultDirectory(bundleID: services.environment.launch.bundleID)
        services.browserProfiles.load(directory: profilesDirectory, importStore: services.onboarding.importStore)
        return profilesDirectory
    }

    /// Bookmarks, history, the first-party page schemes and the page host's statics.
    func registerBrowserData(services: AppServices, profilesDirectory: URL) {
        services.bookmarks.start(directory: profilesDirectory, importStore: services.onboarding.importStore)
        services.history.start(supportDirectory: profilesDirectory.deletingLastPathComponent())
        // cmux-page:// first-party pages for Chromium, before any window can start it.
        FirstPartyPageSchemes.install()
        // The page host already exists (`registerFirstWindowHooks` reads it through `services.iconPicker`) but has opened no page;
        // the statics forward to it for page views not yet made through `webUI.open`
        // (p13-webui-006 to 009 move them, 010 deletes the statics).
        PageWebView.openPanel = services.webUI.openPanel
        PageWebView.chromiumHosting = services.webUI.chromium
    }

    /// The Chromium runtime pack check: it wires the engine reason at once; its download waits until asked.
    /// After two quick unexpected ends in a row, Chromium starts only when the user reloads a browser tab.
    func registerChromiumRuntime(services: AppServices) {
        services.startChromiumRuntime()
    }
}
