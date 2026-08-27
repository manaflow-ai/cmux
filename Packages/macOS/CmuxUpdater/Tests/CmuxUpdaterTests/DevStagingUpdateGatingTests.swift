import Foundation
import Sparkle
import Testing
@testable import CmuxUpdater

/// Regression coverage for https://github.com/manaflow-ai/cmux/issues/6292: tagged DEV and
/// staging builds are produced from local source and are not on the public release train, so
/// they must never surface Sparkle's "Update Available" pill from the public appcast.
@MainActor
@Suite struct DevStagingUpdateGatingTests {
    /// The bug: `didFindValidUpdate` recorded the update for every bundle id, surfacing the pill
    /// on DEV/staging builds. A DEV/staging-gated driver must clear the detected update instead.
    @Test func devLikeBundleClearsDetectedUpdateInsteadOfRecording() throws {
        let model = UpdateStateModel()
        let driver = UpdateDriver(
            model: model,
            log: NoopUpdateLog(),
            clock: SystemUpdateClock(),
            isDevLikeBundle: true
        )

        let item = try #require(makeAppcastItem(version: "0.64.99"))
        driver.handleDidFindValidUpdate(item)

        #expect(model.detectedUpdateVersion == nil)
        #expect(!model.showsPill)
    }

    /// The public release train still records the detected update so the passive pill works.
    @Test func publicBundleRecordsDetectedUpdate() throws {
        let model = UpdateStateModel()
        let driver = UpdateDriver(
            model: model,
            log: NoopUpdateLog(),
            clock: SystemUpdateClock(),
            isDevLikeBundle: false
        )

        let item = try #require(makeAppcastItem(version: "0.64.99"))
        driver.handleDidFindValidUpdate(item)

        #expect(model.detectedUpdateVersion == "0.64.99")
        #expect(model.showsPill)
    }

    @Test func classifiesDebugAndStagingBundlesAsDevLike() {
        #expect(UpdateController.isDevLikeBundleIdentifier("com.cmuxterm.app.debug"))
        #expect(UpdateController.isDevLikeBundleIdentifier("com.cmuxterm.app.debug.my-tag"))
        #expect(UpdateController.isDevLikeBundleIdentifier("com.cmuxterm.app.staging"))
        #expect(UpdateController.isDevLikeBundleIdentifier("com.cmuxterm.app.staging.my-tag"))
    }

    @Test func doesNotClassifyPublicOrNightlyOrNilAsDevLike() {
        #expect(!UpdateController.isDevLikeBundleIdentifier("com.cmuxterm.app"))
        #expect(!UpdateController.isDevLikeBundleIdentifier(nil))
        // A look-alike that is neither the exact base id nor a dotted suffix must not match.
        #expect(!UpdateController.isDevLikeBundleIdentifier("com.cmuxterm.app.debugger"))
        #expect(!UpdateController.isDevLikeBundleIdentifier("com.cmuxterm.app.stagingx"))
    }

    /// A manual "Check for Updates" on a DEV/staging build must not query the public appcast or
    /// offer the public release for install — it short-circuits to "No Updates Available" before
    /// starting Sparkle. (Manual checks are the path that survived the passive-pill gating.)
    @Test func devLikeBundleManualCheckIsSuppressed() throws {
        let suiteName = "com.cmuxterm.updatertests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let controller = UpdateController(
            log: NoopUpdateLog(),
            clock: SystemUpdateClock(),
            hostBundle: .main,
            defaults: defaults,
            isDevLikeBundle: true
        )
        controller.checkForUpdates()

        // No query / no checking state — the manual check resolves to notFound synchronously.
        guard case .notFound = controller.model.state else {
            Issue.record("dev/staging manual check should surface .notFound, got \(controller.model.state)")
            return
        }
    }

    /// A DEV/staging build disables Sparkle's automatic checks so its scheduler never queries the
    /// public appcast. (The override is also re-asserted before `start()`, so the DEBUG
    /// permission-reset path cannot undo it.)
    @Test func devLikeBundleDisablesAutomaticChecks() throws {
        let suiteName = "com.cmuxterm.updatertests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        _ = UpdateController(
            log: NoopUpdateLog(),
            clock: SystemUpdateClock(),
            hostBundle: .main,
            defaults: defaults,
            isDevLikeBundle: true
        )
        #expect(defaults.bool(forKey: UpdateSettings.automaticChecksKey) == false)
    }

    /// The public release train keeps automatic checks enabled.
    @Test func publicBundleLeavesAutomaticChecksEnabled() throws {
        let suiteName = "com.cmuxterm.updatertests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        _ = UpdateController(
            log: NoopUpdateLog(),
            clock: SystemUpdateClock(),
            hostBundle: .main,
            defaults: defaults,
            isDevLikeBundle: false
        )
        #expect(defaults.bool(forKey: UpdateSettings.automaticChecksKey) == true)
    }

    /// Builds a minimal valid `SUAppcastItem` for a version string (nested helper, not API).
    private func makeAppcastItem(version: String) -> SUAppcastItem? {
        let enclosure: [String: Any] = [
            "url": "https://example.com/cmux.zip",
            "length": "1024",
            "sparkle:version": version,
            "sparkle:shortVersionString": version,
        ]
        let dictionary: [String: Any] = [
            "title": "cmux \(version)",
            "pubDate": "Wed, 25 Mar 2026 12:00:00 +0000",
            "enclosure": enclosure,
        ]
        return SUAppcastItem(dictionary: dictionary)
    }
}
