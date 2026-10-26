import CmuxNextPages
import CmuxNextSettings
import Foundation

// Launch calls for pages and the browser: page roots, profiles, bookmarks, history, first-party
// schemes and the browser preferences (task 014, see Startup+Core.swift).
extension AppDelegate {
    /// The diff, file and agent activity pages' files, which live in the app bundle (markdown-viewer/webviews-app).
    func registerPageRoots() {
        PageDescriptor.registerDiffRoot()
        PageDescriptor.registerFilePageRoots()
        PageDescriptor.registerAgentActivityRoot()
    }

    /// What an engine reads when it makes a page or starts, before any does (managed policy included).
    func registerBrowserTabPreferences(services: AppServices, settings: SettingsController) {
        services.cache.browserTabs.preference.follow(settings)
        BrowserLinkClickPreference.follow(settings, webKit: services.cache.webKit, chromium: services.cache.chromium)
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
        FirstPartyPageSchemes.install(processGroups: services.features.isEnabled(.pageProcessGroups))
        // The page host already exists (`services.iconPicker` above reads it) but has opened no page;
        // the statics forward to it for page views not yet made through `webUI.open`
        // (p13-webui-006 to 009 move them, 010 deletes the statics).
        PageWebView.openPanel = services.webUI.openPanel
        PageWebView.chromiumHosting = services.webUI.chromium
    }
}
