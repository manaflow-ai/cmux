import Testing
@testable import CmuxMobileShellUI

/// Startup admission contract for an explicitly injected attach URL.
///
/// The original version of this suite was written against a
/// `connectInjectedAttach(_:attachURL:_:)` coordinator API that was reworked
/// before it merged, so the file has not compiled since it landed — and a
/// compile-broken test target blocks every `cmux.xctestplan` run (the plan
/// builds all of its targets even under `-only-testing`). These tests assert
/// the same admission contract against the coordinator API that shipped; the
/// URL-connect side effects live in `CMUXMobileRootView`, which claims and
/// finishes attempts through exactly these entry points.
@Suite
struct MobileInjectedAttachStartupTests {
    @Test
    @MainActor
    func connectedInjectedAttachConsumesStartupWithoutFallback() throws {
        let coordinator = MobileStartupConnectionCoordinator()
        let attempt = try #require(coordinator.claimInjectedAttach())

        let shouldFallBack = coordinator.finishInjectedAttach(attempt, outcome: .connected)

        #expect(!shouldFallBack)
        #expect(!coordinator.shouldFallBackFromInjectedAttach)
        // A consumed explicit route keeps owning startup: the saved-Mac
        // reconnect must not also dial.
        #expect(coordinator.claimStoredReconnect() == nil)
    }

    @Test
    @MainActor
    func approvalGatedInjectedAttachConsumesStartupWithoutFallback() throws {
        let coordinator = MobileStartupConnectionCoordinator()
        let attempt = try #require(coordinator.claimInjectedAttach())

        let shouldFallBack = coordinator.finishInjectedAttach(
            attempt, outcome: .awaitingUserApproval
        )

        #expect(!shouldFallBack)
        #expect(!coordinator.shouldFallBackFromInjectedAttach)
        // An attach parked on the Mac-side approval prompt still owns startup:
        // the saved-Mac reconnect dialing underneath it would race the very
        // connection the user is approving.
        #expect(coordinator.claimStoredReconnect() == nil)
    }

    @Test
    @MainActor
    func failedInjectedAttachReleasesStartupToStoredReconnect() throws {
        let coordinator = MobileStartupConnectionCoordinator()
        let attempt = try #require(coordinator.claimInjectedAttach())

        let shouldFallBack = coordinator.finishInjectedAttach(attempt, outcome: .failed)

        #expect(shouldFallBack)
        #expect(coordinator.shouldFallBackFromInjectedAttach)
        // A failed explicit route releases startup so the authenticated shell
        // is not stranded disconnected.
        #expect(coordinator.claimStoredReconnect() != nil)
    }

    @Test
    @MainActor
    func onlyOneStartupSourceCanClaimAdmission() throws {
        let coordinator = MobileStartupConnectionCoordinator()

        #expect(coordinator.claimInjectedAttach() != nil)
        #expect(coordinator.claimInjectedAttach() == nil)
        #expect(coordinator.claimStoredReconnect() == nil)
    }
}
