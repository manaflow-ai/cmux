import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextPages
@testable import CmuxNextSidebar
import CmuxNextSettings
@testable import CmuxNextUpdater
import Foundation
import Testing

@MainActor
struct LaunchPolishVisibilityTests {
    @Test func appStoreStaysInStoredLayoutButIsFilteredWhenPreviewFeaturesAreOff() {
        let stored = SidebarLayoutDocument.defaults
        let hidden = SidebarRows.visibleLayout(stored, showAppStore: false)
        #expect(stored.firstItem(with: .app("cmux/app-store")) != nil)
        #expect(hidden.firstItem(with: .app("cmux/app-store")) == nil)
        #expect(SidebarRows.visibleLayout(stored, showAppStore: true) == stored.withoutChats)
    }
    @Test func whatsNewCardShowsAfterAnUpdateWithPreviewsOffByDefault() async throws {
        // User 13935: What's New shows after every update, no Labs gate; a Settings toggle turns it off.
        let suite = "launch-polish-visibility-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let center = WhatsNewCenter(currentVersion: "1.0.0", defaults: defaults, sources: [])
        let settings = CmuxConfigSnapshot.parse(.object([:]), validDensities: [], validMetrics: [])
        #expect(!settings.previewFeatures)
        #expect(settings.updates.showWhatsNew == true)
        center.isItemEnabled = settings.updates.showWhatsNew
        await center.load().value
        #expect(center.debugPretendUpdated(from: "0.9.0"))
        #expect(center.showsUpdatedCard)
    }

    @Test func whatsNewCardHidesWhenTheSettingIsTurnedOffAndKeepsTheUpdate() async throws {
        let suite = "launch-polish-visibility-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let center = WhatsNewCenter(currentVersion: "1.0.0", defaults: defaults, sources: [])
        var settings = CmuxConfigSnapshot.parse(.object([:]), validDensities: [], validMetrics: [])
        settings.updates.showWhatsNew = false
        center.isItemEnabled = settings.updates.showWhatsNew
        await center.load().value
        #expect(center.debugPretendUpdated(from: "0.9.0"))
        #expect(!center.showsUpdatedCard)
        #expect(center.isUpdated, "hiding the card preserves the update")
    }

    /// Leo 2026-10-29: "why the fuck does See What's New not fucking open the What's New tab
    /// anymore?" What's New shows with Labs off (user 13935), so its page is no Labs preview:
    /// with it gated the tab, top page and strip all answered nil and nothing opened.
    @Test func whatsNewPageIsNotALabsPreviewPageButTheAppStoreIs() {
        #expect(!InternalPageTabStore.isPreviewPage(InternalPageID.changelog.rawValue))
        #expect(InternalPageTabStore.isPreviewPage(InternalPageID.appStore.rawValue))
    }

    /// Leo 2026-10-30: "WHAT GOOD REASON DO WE HAVE IN THE FIRST PLACE TO KEEP THIS SHIT IN FUCKING
    /// LABS IF I FUCKING ASKED FOR THESE FUCKING FEATURES". The palette's and Help menu's What's New
    /// (`updates.whatsNew`) is available with Labs off, the default; the App Store stays a Labs preview.
    @Test func whatsNewActionIsAvailableWithLabsOff() {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        #expect(services.settings?.snapshot.previewFeatures != true)
        #expect(services.registry.unavailableReason(for: "updates.whatsNew") == nil,
                "What's New in the palette and Help menu is still behind Labs")
        #expect(services.registry.settingOffReason("appStore.show") != nil, "the App Store stays a Labs preview")
    }

    /// The update this launch came from, as the old build recorded it.
    static let lastUpdate = WhatsNewLastUpdate(fromVersion: "0.9.0", fromBuild: "90", toVersion: "1.0.0", toBuild: "100",
                                               stagedAt: Date(timeIntervalSince1970: 0),
                                               changelog: UpdateChangelog(version: "1.0.0", date: nil, lines: ["A change"]))

    /// Seeds the last update on `updater` and records what its changelog openers get.
    static func recordOpens(_ updater: UpdaterService) -> () -> (spans: [[String]], plain: Int) {
        updater.whatsNew.lastUpdate = lastUpdate
        var spans: [[String]] = [], plain = 0
        updater.openChangelog = { plain += 1; return true }
        updater.openChangelogSpan = { from, to in spans.append([from, to]); return true }
        return { (spans, plain) }
    }

    /// The "cmux Updated!" card's See What's New opens the changelog for the update's span
    /// through the updater, as the update island's does, not through the palette's
    /// `updates.whatsNew` (a Labs entry until 2026-10-30, unavailable with Labs off then, which left
    /// the card's button doing nothing).
    @Test func updatedCardSeeWhatsNewOpensTheUpdatesSpanWithoutThePaletteAction() throws {
        let suite = "launch-polish-see-whats-new-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let identity = UpdateBuildIdentity(bundleIdentifier: "com.cmuxterm.app.debug.see-whats-new", shortVersion: "1.0.0",
                                           build: "100", minimumSystemVersion: nil,
                                           infoFeedURL: "https://files-next.cmux.com/nightly-next/appcast-arm64.xml", hasPublicKey: false)
        let updater = UpdaterService(identity: identity, policy: ManagedUpdatePolicy { false }, defaults: defaults,
                                     enableSparkle: false, recordsUpdates: false)
        let opens = Self.recordOpens(updater)
        // No `updates.whatsNew` bound: the palette entry is unavailable, as with Labs off.
        SidebarCardFeed.route(.openWhatsNew, registry: ActionRegistry(), updater: updater)
        #expect(opens().spans == [["0.9.0", "1.0.0"]], "See What's New on the Updated card did not open the update's span")
        #expect(opens().plain == 0)
    }

    /// The update toast (the Updated surface island) asks for the same span.
    @Test func updatedToastSeeWhatsNewOpensTheUpdatesSpan() async throws {
        // AppServices reads NSApp (its key window source); without the app object it is nil.
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let opens = Self.recordOpens(services.updater)
        let provider = UpdateSurfaceProvider(kind: .updated, services: services)
        _ = try await provider.call("cmux.changelog.surface.openChangelog", params: [:],
                                    context: PageCallContext(page: "cmux.changelog.surface", userGesture: true))
        #expect(opens().spans == [["0.9.0", "1.0.0"]], "See What's New on the update toast did not open the update's span")
        #expect(opens().plain == 0)
        #expect(services.updater.whatsNew.lastUpdate == Self.lastUpdate, "opening keeps the record; only the card's x clears it")
    }

    /// The span the opener gets becomes the changelog tab's route (`#/?from=&to=`).
    @Test func theUpdatesSpanIsTheChangelogTabsRoute() {
        #expect(ChangelogPageTab.route(from: "0.9.0", to: "1.0.0") == "#/?from=0.9.0&to=1.0.0")
    }
}
