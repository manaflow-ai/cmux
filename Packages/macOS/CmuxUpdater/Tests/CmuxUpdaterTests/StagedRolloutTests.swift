import Foundation
import Testing
@testable import CmuxUpdater

/// A stable release goes out in stages (docs/cmux-next/release-rollout.md): the operator writes
/// `<cmux:rolloutPercent>` into its appcast item and raises it after each stage's crash-free
/// gate. A scheduled check must take the build only on that share of installs; before this, an
/// item reached every install at its next check whatever its percentage said.
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

    private func find(_ item: UpdateAppcastItem, _ harness: Harness) -> UpdateChoice? {
        let box = ChoiceBox()
        harness.controller.driver.showUpdateFound(with: item, reply: { choice in
            MainActor.assumeIsolated { box.choice = choice }
        })
        return box.choice
    }

    /// A seed whose bucket for `version` is below (`inside`) or at least (`!inside`) `percent`.
    private func seed(version: String, percent: Double, inside: Bool) -> UInt64 {
        var seed: UInt64 = 1
        while true {
            let bucket = StagedRollout(seed: seed).bucket(forVersion: version)
            if (Double(bucket) < percent * 100) == inside { return seed }
            seed += 1
        }
    }

    private func harness(seed: UInt64) -> Harness {
        let harness = Harness()
        harness.controller.installsUpdatesInBackground = true
        harness.controller.stagedRollout = StagedRollout(seed: seed)
        return harness
    }

    @Test func theItemCarriesItsPercentageAsWritten() {
        #expect(item(percent: "25").rolloutPercent == "25")
        #expect(item(percent: nil).rolloutPercent == nil)
    }

    @Test func aScheduledCheckOutsideTheStageDoesNotTakeTheBuild() {
        let harness = harness(seed: seed(version: "200", percent: 5, inside: false))
        #expect(find(item(percent: "5"), harness) == .dismiss)
        #expect(harness.model.state.isIdle)
    }

    @Test func aScheduledCheckInsideTheStageTakesTheBuild() {
        let harness = harness(seed: seed(version: "200", percent: 5, inside: true))
        #expect(find(item(percent: "5"), harness) == .install)
    }

    @Test func zeroHaltsTheRolloutForEveryScheduledCheck() {
        for seed: UInt64 in [1, 2, 3, 99, .max] {
            #expect(find(item(percent: "0"), harness(seed: seed)) == .dismiss)
        }
    }

    @Test func aBrokenPercentageHoldsTheBuild() {
        let harness = harness(seed: seed(version: "200", percent: 100, inside: true))
        #expect(find(item(percent: "lots"), harness) == .dismiss)
        #expect(find(item(percent: "120"), harness) == .dismiss)
        #expect(find(item(percent: "-1"), harness) == .dismiss)
    }

    @Test func anItemWithoutAPercentageReachesEveryInstall() {
        #expect(find(item(percent: nil), harness(seed: 7)) == .install)
    }

    @Test func aCheckThePersonStartedTakesTheBuildOutsideTheStage() {
        let harness = harness(seed: seed(version: "200", percent: 1, inside: false))
        harness.controller.driver.showUserInitiatedUpdateCheck(cancellation: {})
        #expect(find(item(percent: "1"), harness) == .install)
    }

    @Test func theControllerKeepsOneSeedPerInstall() {
        let first = Harness()
        let seed = first.controller.stagedRollout?.seed
        #expect(seed != nil)
        #expect(StagedRollout(defaults: first.defaults).seed == seed)
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
