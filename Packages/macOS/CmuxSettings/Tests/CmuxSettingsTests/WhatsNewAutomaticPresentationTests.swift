import Foundation
import Testing
@testable import CmuxSettings

struct WhatsNewAutomaticPresentationTests {
    private let policy = WhatsNewAutomaticPresentation()

    @Test func defaultModeIsQuiet() {
        #expect(AppCatalogSection().whatsNew.defaultValue == .quiet)
        #expect(AppCatalogSection().whatsNew.id == "app.whatsNew")
    }

    @Test func offNeverAnnounces() {
        #expect(policy.decide(mode: .off, flavor: .stable, currentVersion: "0.64.26", lastSeenVersion: "0.64.25") == .none)
        #expect(policy.decide(mode: .off, flavor: .stable, currentVersion: "0.64.26", lastSeenVersion: nil) == .none)
    }

    @Test func quietIndicatesAndSheetPresentsOnANewVersion() {
        #expect(policy.decide(mode: .quiet, flavor: .stable, currentVersion: "0.64.26", lastSeenVersion: "0.64.25") == .indicate(since: "0.64.25"))
        #expect(policy.decide(mode: .sheet, flavor: .stable, currentVersion: "0.64.26", lastSeenVersion: "0.64.25") == .present(since: "0.64.25"))
    }

    @Test func nothingRecordedAnnouncesTheCurrentVersion() {
        #expect(policy.decide(mode: .quiet, flavor: .stable, currentVersion: "0.64.26", lastSeenVersion: nil) == .indicate(since: nil))
        #expect(policy.decide(mode: .sheet, flavor: .rc, currentVersion: "0.64.26-rc.1", lastSeenVersion: nil) == .present(since: nil))
    }

    @Test func freshInstallRecordsWithoutAnnouncing() {
        for mode in WhatsNewPresentationMode.allCases {
            #expect(policy.decide(mode: mode, flavor: .stable, currentVersion: "0.64.26", lastSeenVersion: nil, isFirstRun: true) == .recordCurrent)
        }
        // A first run only matters when nothing is recorded yet.
        #expect(policy.decide(mode: .sheet, flavor: .stable, currentVersion: "0.64.26", lastSeenVersion: "0.64.25", isFirstRun: true) == .present(since: "0.64.25"))
    }

    /// Running an older build after a newer one. The policy does not filter
    /// this itself: it hands the recorded key to the catalog as `since`, and
    /// the catalog's numeric range is what yields nothing to announce. The
    /// recorded key is deliberately left alone so the newer build still
    /// counts as seen when the user goes back to it.
    @Test func aDowngradeDefersToTheCatalogAndKeepsTheRecord() {
        #expect(
            policy.decide(mode: .sheet, flavor: .stable, currentVersion: "0.64.25", lastSeenVersion: "0.64.30")
                == .present(since: "0.64.30")
        )
        #expect(
            policy.decide(mode: .quiet, flavor: .stable, currentVersion: "0.64.25", lastSeenVersion: "0.64.30")
                == .indicate(since: "0.64.30")
        )
    }

    /// A `v` or `V` tag prefix must not disable announcements. Returning `nil`
    /// from `releaseKey` silently turns the whole feature off.
    @Test func aTagPrefixParsesInEitherCase() {
        #expect(WhatsNewAutomaticPresentation.releaseKey("v0.64.25") == "0.64.25")
        #expect(WhatsNewAutomaticPresentation.releaseKey("V0.64.25") == "0.64.25")
        #expect(
            policy.decide(mode: .sheet, flavor: .stable, currentVersion: "V0.64.26", lastSeenVersion: "0.64.25")
                == .present(since: "0.64.25")
        )
    }

    @Test func onlyOncePerVersion() {
        for mode in WhatsNewPresentationMode.allCases {
            #expect(policy.decide(mode: mode, flavor: .stable, currentVersion: "0.64.26", lastSeenVersion: "0.64.26") == .none)
        }
    }

    @Test func nightlyBuildsOfOneReleaseAnnounceOnce() {
        #expect(policy.decide(mode: .sheet, flavor: .nightly, currentVersion: "0.64.26-nightly.900", lastSeenVersion: "0.64.26") == .none)
        #expect(policy.decide(mode: .sheet, flavor: .nightly, currentVersion: "0.64.26-nightly.901", lastSeenVersion: "0.64.25") == .present(since: "0.64.25"))
        // A recorded nightly-shaped string still compares by release key.
        #expect(policy.decide(mode: .quiet, flavor: .nightly, currentVersion: "0.64.26-nightly.905", lastSeenVersion: "0.64.26-nightly.900") == .none)
    }

    @Test func devBuildsNeverAnnounceOnTheirOwn() {
        #expect(policy.decide(mode: .sheet, flavor: .dev, currentVersion: "0.64.26", lastSeenVersion: "0.64.25") == .none)
    }

    @Test func unparseableCurrentVersionAnnouncesNothing() {
        #expect(policy.decide(mode: .sheet, flavor: .stable, currentVersion: "abc", lastSeenVersion: nil) == .none)
    }

    @Test(arguments: [
        ("0.64.25", "0.64.25"),
        ("v0.64.25", "0.64.25"),
        ("0.64.25-nightly.812", "0.64.25"),
        ("0.64.25-rc.1", "0.64.25"),
        (" 1.2 ", "1.2"),
        ("1.2.x", "1.2"),
    ])
    func releaseKeyTakesTheNumericPrefix(input: String, expected: String) {
        #expect(WhatsNewAutomaticPresentation.releaseKey(input) == expected)
    }

    @Test func releaseKeyRejectsNonNumericVersions() {
        #expect(WhatsNewAutomaticPresentation.releaseKey("") == nil)
        #expect(WhatsNewAutomaticPresentation.releaseKey("nightly") == nil)
    }

    @Test func modeRoundTripsThroughUserDefaults() throws {
        let suite = "WhatsNewAutomaticPresentationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = AppCatalogSection().whatsNew
        let client = UserDefaultsSettingsClient(defaults: defaults)
        #expect(client.value(for: key) == .quiet)
        client.set(.sheet, for: key)
        #expect(defaults.string(forKey: "whatsNewPresentationMode") == "sheet")
        defaults.set("loud", forKey: "whatsNewPresentationMode")
        #expect(client.value(for: key) == .quiet)
    }

    // MARK: - After the catalog load

    /// `decide` runs before the catalog fetch, so the setting it read can be
    /// stale by the time the catalog arrives. The reread only ever narrows
    /// that decision.
    @Test func switchingOffDuringTheLoadSuppressesTheLaunch() {
        for decided in [true, false] {
            #expect(WhatsNewAutomaticPresentation.launchOutcome(
                decidedToPresent: decided,
                liveMode: .off,
                announcedVersion: "0.64.25",
                liveAnnouncedVersion: "0.64.25"
            ) == .suppress)
        }
    }

    /// The setting promises the recap opens once after the first launch of a
    /// new version. A launch that decided on the quiet indicator therefore
    /// keeps the indicator even if the user picks Show Once while the catalog
    /// is loading; that choice takes effect on the next launch.
    @Test func aQuietLaunchDoesNotEscalateToASheet() {
        #expect(WhatsNewAutomaticPresentation.launchOutcome(
            decidedToPresent: false,
            liveMode: .sheet,
            announcedVersion: "0.64.25",
            liveAnnouncedVersion: "0.64.25"
        ) == .indicate)
    }

    @Test func aLaunchThatDecidedToPresentStillPresents() {
        #expect(WhatsNewAutomaticPresentation.launchOutcome(
            decidedToPresent: true,
            liveMode: .sheet,
            announcedVersion: "0.64.25",
            liveAnnouncedVersion: "0.64.25"
        ) == .presentSheet)
        // Switched from Show Once to the indicator mid-load.
        #expect(WhatsNewAutomaticPresentation.launchOutcome(
            decidedToPresent: true,
            liveMode: .quiet,
            announcedVersion: "0.64.25",
            liveAnnouncedVersion: "0.64.25"
        ) == .indicate)
    }

    /// An on-demand open that starts during the launch load records the
    /// version as seen when it finishes, which consumes this version's one
    /// announcement. The launch path must not announce it a second time on
    /// content the user has already dismissed.
    @Test func aConcurrentOpenThatRecordedTheVersionSuppressesTheLaunch() {
        #expect(WhatsNewAutomaticPresentation.launchOutcome(
            decidedToPresent: true,
            liveMode: .sheet,
            announcedVersion: "0.64.25",
            liveAnnouncedVersion: "0.64.26"
        ) == .suppress)
        #expect(WhatsNewAutomaticPresentation.launchOutcome(
            decidedToPresent: false,
            liveMode: .quiet,
            announcedVersion: nil,
            liveAnnouncedVersion: "0.64.26"
        ) == .suppress)
        // Nothing recorded before or after: no concurrent open happened.
        #expect(WhatsNewAutomaticPresentation.launchOutcome(
            decidedToPresent: true,
            liveMode: .sheet,
            announcedVersion: nil,
            liveAnnouncedVersion: nil
        ) == .presentSheet)
    }
}
