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
}
