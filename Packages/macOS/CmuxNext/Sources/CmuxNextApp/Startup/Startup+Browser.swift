import CmuxNextFeatures
import CmuxNextLaunch
import CmuxNextPages
import CmuxNextSettings
import CmuxNextWakeups
import Foundation

/// The browser's launch calls, its data ordered before the first page engine (p08-startup-028).
///
/// In the launch turn, before any window: the profiles' launch read starts (off main) and every browser
/// tab's page waits for it by event (`TabContentCache.enginesAwait`), so no engine makes a page with a
/// profile chosen before the profiles were read; the engine preferences, the first-party page schemes
/// and the page host's Chromium hosting are set before any page picks an engine. After the first frame:
/// the follows that neither the first frame nor an engine reads, one post each (`LaunchServicePosts.browserFollows`).
///
/// Chrome opens a profile's first browser window only from the profile's loaded callback
/// (`ProfileManager::CreateProfileAsync`, chrome/browser/profiles/profile_manager.cc, used by
/// `StartupBrowserCreator`, chrome/browser/ui/startup/startup_browser_creator.cc).
@MainActor
struct BrowserStartup {
    let services: AppServices

    /// Starts the profiles' launch read; until it is done, every browser tab's page waits.
    ///
    /// - Returns: The profiles' directory, where bookmarks live too.
    func readProfiles() -> URL {
        let directory = BrowserProfileService.defaultDirectory(bundleID: services.environment.launch.bundleID)
        let loaded = LaunchReadEvent("BrowserProfiles.loaded")
        services.cache.enginesAwait = loaded
        let profiles = services.browserProfiles
        profiles.load(directory: directory, importStore: services.onboarding.importStore)
        // task-owner: one-shot; resumes once, on the profiles' load (BrowserProfileService.loaded resumes its waiters then)
        Task { [weak profiles] in
            await profiles?.loaded()
            loaded.signal()
        }
        return directory
    }

    /// Bookmarks and history (each reads its files off main), the first-party page schemes and the page host's statics.
    func startData(profilesDirectory: URL) {
        services.bookmarks.start(directory: profilesDirectory, importStore: services.onboarding.importStore)
        services.history.start(supportDirectory: profilesDirectory.deletingLastPathComponent())
        // cmux-page:// first-party pages for Chromium, before any window can start it.
        FirstPartyPageSchemes.install(processGroups: services.features.isEnabled(.pageProcessGroups))
        // The page host already exists (`services.iconPicker` reads it) but has opened no page;
        // the statics forward to it for page views not yet made through `webUI.open`
        // (p13-webui-006 to 009 move them, 010 deletes the statics).
        PageWebView.openPanel = services.webUI.openPanel
        PageWebView.chromiumHosting = services.webUI.chromium
    }

    /// What an engine reads when it makes a page or starts, before any does: the default and per-site
    /// engines a new tab takes, and the link click mapping with the ad blocker and the managed browser
    /// policy (Chromium reads those at its start; managed policy applies before any engine, p08-startup.md 0).
    func followEnginePreferences(_ settings: SettingsController) {
        let cache = services.cache
        cache.browserTabs.preference.follow(settings)
        BrowserLinkClickPreference.follow(settings, webKit: cache.webKit, chromium: cache.chromium)
    }

    /// History's daemon sync and the location trail's scope, after the first frame.
    func postFollows(_ settings: SettingsController, on startup: StartupScheduler) {
        LaunchServicePosts.browserFollows(
            historyDaemonSync: { [weak services, weak settings] in
                if let settings { services?.history.startDaemonSync(settings: settings) }
            },
            locationTrailScope: { [weak services, weak settings] in
                if let settings { services?.locationTrail.watchScope(settings: settings) }
            }).post(on: startup)
    }
}
