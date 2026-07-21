import Testing
import CmuxUpdater
@testable import CmuxUpdaterUI

@MainActor
@Suite("Update pill no-update interaction")
struct UpdatePillNotFoundInteractionTests {
    @Test func actionableResultsOpenDetailsInsteadOfBeingAcknowledged() {
        let actionableReasons: [UpdateState.NotFound.Reason] = [
            .systemTooOld(latestVersion: "0.64.20", minimumSystemVersion: "15.0"),
            .systemTooNew(latestVersion: "0.64.20", maximumSystemVersion: "26.0"),
            .unsupportedHardware(latestVersion: "0.64.20"),
            .developmentBuild,
            .unknown,
        ]

        for reason in actionableReasons {
            let result = UpdateState.NotFound(reason: reason, acknowledgement: {})
            #expect(UpdatePill.notFoundTapBehavior(for: result) == .showDetails)
        }
    }

    @Test func lowInformationSuccessAcknowledgesDirectly() {
        let reasons: [UpdateState.NotFound.Reason] = [
            .upToDate,
            .newerThanLatest(latestVersion: "0.64.20"),
        ]

        for reason in reasons {
            let result = UpdateState.NotFound(reason: reason, acknowledgement: {})
            #expect(UpdatePill.notFoundTapBehavior(for: result) == .acknowledge)
        }
    }

    @Test func unknownResultOffersRetry() {
        #expect(UpdatePill.offersRetry(for: .init(reason: .unknown, acknowledgement: {})))
        #expect(!UpdatePill.offersRetry(for: .init(reason: .developmentBuild, acknowledgement: {})))
    }

    @Test func unknownRetryUsesIntentPreservingHostAction() {
        let actions = UpdateActionsSpy()
        UpdatePill.performNoUpdateRetry(using: actions)

        #expect(actions.retryNoUpdateCount == 1)
        #expect(actions.manualCheckCount == 0)
        #expect(actions.attemptUpdateCount == 0)
    }

    @Test func primaryInstallUsesFreshLatestVersionHostAction() {
        let actions = UpdateActionsSpy()
        UpdatePill.performInstall(using: actions)

        #expect(actions.attemptUpdateCount == 1)
        #expect(actions.manualCheckCount == 0)
        #expect(actions.retryNoUpdateCount == 0)
    }
}

@MainActor
private final class UpdateActionsSpy: UpdateActionsHost {
    var manualCheckCount = 0
    var attemptUpdateCount = 0
    var retryNoUpdateCount = 0

    func checkForUpdatesInCustomUI() { manualCheckCount += 1 }
    func attemptUpdate() { attemptUpdateCount += 1 }
    func acknowledgeNoUpdate() {}
    func retryNoUpdate() { retryNoUpdateCount += 1 }
    var updateLogPath: String { "/tmp/cmux-update-test.log" }
}
