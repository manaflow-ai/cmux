import Foundation
import Sparkle
import Testing
@testable import CmuxUpdater

/// A stable release goes out in stages (docs/cmux-next/release-rollout.md): the operator writes
/// `<cmux:rolloutPercent>` into its appcast item and raises it after each stage's crash-free
/// gate. A scheduled check must take the build only on that share of installs, whichever Sparkle
/// driver runs it; before this, an item reached every install at its next check whatever its
/// percentage said.
@MainActor
@Suite struct StagedRolloutTests {
    private func item(version: String = "200", percent: String?) -> UpdateAppcastItem {
        var dictionary: [String: Any] = [
            "title": "cmux 1.2.0",
            "enclosure": [
                "url": "https://example.com/cmux-macos-\(version).dmg",
                "length": "221218951",
                "sparkle:version": version,
                "sparkle:shortVersionString": "1.2.0",
            ],
        ]
        if let percent { dictionary[StagedRollout.element] = percent }
        return UpdateAppcastItem(dictionary: dictionary)!
    }

    /// A seed whose bucket for `version` is below (`inside`) or at least (`!inside`) `percent`.
    private func seed(version: String, percent: Double, inside: Bool) -> UInt64 {
        var seed: UInt64 = 1
        while (Double(StagedRollout(seed: seed).bucket(forVersion: version)) < percent * 100) != inside { seed += 1 }
        return seed
    }

    /// The bridge Sparkle calls, over a driver with `seed`.
    private func bridge(seed: UInt64) -> SparkleDriverBridge {
        let driver = UpdateDriver(model: UpdateStateModel(), log: NoopUpdateLog(), clock: TestDeadlineClock())
        driver.stagedRollout = StagedRollout(seed: seed)
        return SparkleDriverBridge(driver: driver)
    }

    /// Whether Sparkle may go on with `item` on a `check`.
    private func proceeds(_ item: UpdateAppcastItem, _ check: SPUUpdateCheck, seed: UInt64) -> Bool {
        do {
            try bridge(seed: seed).forwardShouldProceed(with: item, check: check)
            return true
        } catch {
            #expect((error as NSError).domain == StagedRollout.errorDomain)
            return false
        }
    }

    /// Sparkle asks `shouldProceedWithUpdate` before it records the update as found and before the
    /// user driver or the silent automatic driver acts: the one place every scheduled path passes.
    @Test func sparkleAsksTheBridgeBeforeItProceeds() {
        let bridge = bridge(seed: 1)
        #expect(bridge.responds(to: NSSelectorFromString("updater:shouldProceedWithUpdate:updateCheck:error:")))
    }

    @Test func theControllerKeepsOneSeedPerInstall() {
        let harness = Harness()
        let seed = harness.controller.stagedRollout?.seed
        #expect(seed != nil)
        #expect(StagedRollout(defaults: harness.defaults).seed == seed)
    }

    @Test func theItemCarriesItsPercentageAsWritten() {
        #expect(item(percent: "25").rolloutPercent == "25")
        #expect(item(percent: nil).rolloutPercent == nil)
    }

    @Test func aScheduledCheckOutsideTheStageDoesNotProceed() {
        #expect(!proceeds(item(percent: "5"), .updatesInBackground, seed: seed(version: "200", percent: 5, inside: false)))
    }

    @Test func aScheduledCheckInsideTheStageProceeds() {
        #expect(proceeds(item(percent: "5"), .updatesInBackground, seed: seed(version: "200", percent: 5, inside: true)))
    }

    @Test func aCheckThePersonStartedProceedsOutsideTheStage() {
        let outside = seed(version: "200", percent: 1, inside: false)
        #expect(proceeds(item(percent: "1"), .updates, seed: outside))
        #expect(proceeds(item(percent: "1"), .updateInformation, seed: outside))
    }

    @Test func zeroHaltsEveryScheduledCheck() {
        for seed: UInt64 in [1, 2, 3, 99, .max] {
            #expect(!proceeds(item(percent: "0"), .updatesInBackground, seed: seed))
        }
    }

    @Test func aBrokenPercentageHoldsTheBuild() {
        let inside = seed(version: "200", percent: 100, inside: true)
        for raw in ["lots", "120", "-1", ""] {
            #expect(!proceeds(item(percent: raw), .updatesInBackground, seed: inside), "\(raw)")
        }
    }

    @Test func anItemWithoutAPercentageReachesEveryInstall() {
        #expect(proceeds(item(percent: nil), .updatesInBackground, seed: 7))
    }

    @Test func eachStageReachesItsShareOfInstalls() {
        let installs = (0 ..< 20_000).map { StagedRollout(seed: UInt64($0) &* 0x9e37_79b9_7f4a_7c15) }
        for percent in [1.0, 5, 25, 50] {
            let offered = installs.filter { $0.offers(version: "200", rawPercent: String(percent)) }.count
            let share = Double(offered) / Double(installs.count) * 100
            #expect(abs(share - percent) < max(0.5, percent * 0.1), "stage \(percent) % reached \(share) %")
        }
    }

    @Test func raisingTheStageKeepsEveryInstallThatHadTheBuild() {
        for raw in 0 ..< 2_000 {
            let rollout = StagedRollout(seed: UInt64(raw) &* 0x9e37_79b9_7f4a_7c15)
            if rollout.offers(version: "200", rawPercent: "5") {
                #expect(rollout.offers(version: "200", rawPercent: "25"))
            }
        }
    }

    @Test func eachBuildStartsOnADifferentShareOfInstalls() {
        let installs = (0 ..< 20_000).map { StagedRollout(seed: UInt64($0) &* 0x9e37_79b9_7f4a_7c15) }
        let first = installs.filter { $0.offers(version: "200", rawPercent: "10") }.count
        let both = installs.filter { $0.offers(version: "200", rawPercent: "10") && $0.offers(version: "201", rawPercent: "10") }.count
        // Independent buckets: about 10 % of the first build's 10 %, not all of it.
        #expect(Double(both) < Double(first) * 0.2)
    }

    @Test func thePercentageAcceptsASignAndRejectsOutOfRangeValues() {
        #expect(StagedRollout.percent("25%") == 25)
        #expect(StagedRollout.percent(" 2.5 ") == 2.5)
        #expect(StagedRollout.percent("100") == 100)
        #expect(StagedRollout.percent("100.5") == nil)
        #expect(StagedRollout.percent("nan") == nil)
        #expect(StagedRollout.percent("") == nil)
    }
}
