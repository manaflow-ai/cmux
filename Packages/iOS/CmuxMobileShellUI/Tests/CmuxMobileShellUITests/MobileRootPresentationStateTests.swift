import Testing
import CmuxMobileShell

@testable import CmuxMobileShellUI

@Suite("Root sheet presentation state")
struct MobileRootPresentationStateTests {
    @Test func versionApprovalIsNotAManualPairingSurface() {
        let approval = PairingPresentation.versionApproval

        #expect(!approval.showsManualPairingControls)
        #expect(!approval.showsScanner)
        #expect(approval.analyticsEntry == "version_approval")
    }

    @Test func introductionStartsTailscaleScannerWithoutAUsableAuthorization() {
        var state = MobileRootPresentationState()

        #expect(state.apply(.presentAutoConnectMigrationIfIdle) == .none)
        #expect(state.presentation == .autoConnectMigrationIntroduction)
        #expect(state.isRootSheetPresented)

        let scanner = PairingPresentation.scanner(entry: .autoConnectMigration)
        #expect(
            state.apply(.setUpTailscale(status: .pairingRequired))
                == .setUpTailscale(requiresPairing: true)
        )
        #expect(state.presentation == .pairing(scanner))
        #expect(state.isRootSheetPresented)
    }

    @Test func introductionSelectsAuthorizedTailscaleWithoutOpeningScanner() {
        var state = MobileRootPresentationState()
        state.apply(.presentAutoConnectMigrationIfIdle)

        #expect(
            state.apply(.setUpTailscale(status: .authorized))
                == .setUpTailscale(requiresPairing: false)
        )
        #expect(state.isIdle)
    }

    @Test func introductionWaitsForLoadingTailscaleAuthorizationBeforePairing() {
        var state = MobileRootPresentationState()
        state.apply(.presentAutoConnectMigrationIfIdle)

        #expect(
            state.apply(.setUpTailscale(status: .loadingAuthorization))
                == .setUpTailscale(requiresPairing: false)
        )
        #expect(state.isIdle)
    }

    @Test func tailscaleRequirementLatchesAcrossShellLoading() {
        var state = MobileTailscaleSetupPromptState()

        state.apply(.selectedTailscale(requiresPairing: true))
        #expect(state.requiresPairing)

        state.apply(.shellStatusChanged(.loadingAuthorization))
        #expect(state.requiresPairing)

        state.apply(.shellStatusChanged(.pairingRequired))
        #expect(state.requiresPairing)
    }

    @Test func tailscaleRequirementFollowsDurableReadinessAcrossLaunches() {
        var state = MobileTailscaleSetupPromptState()

        state.apply(.shellStatusChanged(.loadingAuthorization))
        #expect(!state.requiresPairing)

        state.apply(.shellStatusChanged(.pairingRequired))
        #expect(state.requiresPairing)

        state.apply(.shellStatusChanged(.authorized))
        #expect(!state.requiresPairing)
        #expect(state.presentation == .followsShell)
    }

    @Test func interactiveIntroductionDismissalRequestsAcknowledgement() {
        var state = MobileRootPresentationState()
        state.apply(.presentAutoConnectMigrationIfIdle)

        #expect(state.apply(.sheetDidRequestDismissal) == .acknowledgeAutoConnectMigration)
        #expect(state.presentation == nil)
    }

    @Test func continuingWithAutoConnectAcknowledgesAndClearsTheSlot() {
        var state = MobileRootPresentationState()
        state.apply(.presentAutoConnectMigrationIfIdle)

        #expect(
            state.apply(.useAutoConnect) == .useAutoConnect
        )
        #expect(state.isIdle)
        #expect(state.apply(.useAutoConnect) == .none)
        #expect(state.isIdle)
    }

    @Test func pairingPreemptsIntroductionWithoutAcknowledgementAndAllowsReentry() {
        var state = MobileRootPresentationState()
        state.apply(.presentAutoConnectMigrationIfIdle)

        let scanner = PairingPresentation.scanner(entry: .settingsReplay)
        #expect(state.apply(.presentPairing(scanner)) == .none)
        #expect(state.presentation == .pairing(scanner))

        #expect(state.apply(.sheetDidRequestDismissal) == .finishPairing)
        #expect(state.presentation == nil)

        #expect(state.apply(.presentAutoConnectMigrationIfIdle) == .none)
        #expect(state.presentation == .autoConnectMigrationIntroduction)
    }

    @Test func migrationNeverReplacesAnActivePairingPresentation() {
        var state = MobileRootPresentationState()
        let pairing = PairingPresentation.manual
        state.apply(.presentPairing(pairing))

        #expect(state.apply(.presentAutoConnectMigrationIfIdle) == .none)
        #expect(state.presentation == .pairing(pairing))
    }

    @Test func computersOwnsRootSheetAndCanTransitionToPairing() {
        var state = MobileRootPresentationState()

        #expect(state.apply(.presentComputers) == .none)
        #expect(state.presentation == .computers)
        #expect(state.isRootSheetPresented)

        let pairing = PairingPresentation.manual
        #expect(state.apply(.presentPairing(pairing)) == .none)
        #expect(state.presentation == .pairing(pairing))
        #expect(state.isRootSheetPresented)
    }

    @Test func settingsCanHandItsSheetToComputersInPlace() {
        var state = MobileRootPresentationState()
        state.apply(.presentSettings)

        #expect(state.apply(.presentComputers) == .none)
        #expect(state.presentation == .computers)
        #expect(state.isRootSheetPresented)

        #expect(state.apply(.dismissComputers) == .retryAutoConnectMigration)
        #expect(state.isIdle)
    }

    @Test func computersNeverReplacesAPairingPresentation() {
        var state = MobileRootPresentationState()
        let pairing = PairingPresentation.manual
        state.apply(.presentPairing(pairing))

        #expect(state.apply(.presentComputers) == .none)
        #expect(state.presentation == .pairing(pairing))
    }

    /// A child Settings dismissal can re-present the migration introduction
    /// (its retry effect) before the queued Computers follow-up runs; the
    /// user's explicit Computers request must still win the slot.
    @Test func computersPreemptsTheMigrationIntroduction() {
        var state = MobileRootPresentationState()
        state.apply(.presentAutoConnectMigrationIfIdle)
        #expect(state.presentation == .autoConnectMigrationIntroduction)

        #expect(state.apply(.presentComputers) == .none)
        #expect(state.presentation == .computers)
        #expect(state.isRootSheetPresented)
    }

    @Test func computersDismissalClearsRootSlot() {
        var state = MobileRootPresentationState()
        state.apply(.presentComputers)

        #expect(state.apply(.dismissComputers) == .retryAutoConnectMigration)
        #expect(state.isIdle)
        #expect(!state.isRootSheetPresented)
    }

    @Test func childModalBlocksMigrationUntilItsDismissalCompletes() {
        var state = MobileRootPresentationState()
        let child = MobileRootPresentationState.ChildPresentation.workspaceDeviceTree

        #expect(state.apply(.presentChild(child)) == .none)
        #expect(state.presentation == .child(child))
        #expect(state.isPresentingChild(child))

        #expect(state.apply(.presentAutoConnectMigrationIfIdle) == .none)
        #expect(state.presentation == .child(child))

        #expect(state.apply(.dismissChild(child)) == .none)
        #expect(
            state.presentation
                == .dismissingChild(child, pendingPairing: nil)
        )
        #expect(!state.isPresentingChild(child))
        #expect(!state.isIdle)
        #expect(state.apply(.presentAutoConnectMigrationIfIdle) == .none)
        #expect(
            state.presentation
                == .dismissingChild(child, pendingPairing: nil)
        )

        #expect(
            state.apply(.childDidDismiss(child))
                == .retryAutoConnectMigration
        )
        #expect(state.isIdle)

        #expect(state.apply(.presentAutoConnectMigrationIfIdle) == .none)
        #expect(state.presentation == .autoConnectMigrationIntroduction)
    }

    @Test func rootSettingsBlocksMigrationOnTheAlwaysMountedSheetHost() {
        var state = MobileRootPresentationState()

        #expect(state.apply(.presentSettings) == .none)
        #expect(state.presentation == .settings)
        #expect(state.isRootSheetPresented)

        #expect(state.apply(.presentAutoConnectMigrationIfIdle) == .none)
        #expect(state.presentation == .settings)

        #expect(
            state.apply(.dismissSettings(presentAutoConnectMigration: true)) == .none
        )
        #expect(state.presentation == .autoConnectMigrationIntroduction)
        #expect(state.isRootSheetPresented)
    }

    @Test func rootSettingsDismissesWhenNoMigrationIsPending() {
        var state = MobileRootPresentationState()
        state.apply(.presentSettings)

        #expect(
            state.apply(.dismissSettings(presentAutoConnectMigration: false)) == .none
        )
        #expect(state.isIdle)
    }

    @Test(arguments: MobileRootPresentationState.WorkspaceListPresentation.allCases)
    func everyWorkspaceListPresentationBlocksMigration(
        _ presentation: MobileRootPresentationState.WorkspaceListPresentation
    ) {
        var state = MobileRootPresentationState()
        let child = MobileRootPresentationState.ChildPresentation.workspaceList(presentation)

        #expect(state.apply(.presentChild(child)) == .none)
        #expect(state.presentation == .child(child))
        #expect(state.apply(.presentAutoConnectMigrationIfIdle) == .none)
        #expect(state.presentation == .child(child))

        #expect(state.apply(.dismissChild(child)) == .none)
        #expect(state.apply(.childDidDismiss(child)) == .retryAutoConnectMigration)
        #expect(state.isIdle)
    }

    @Test(arguments: MobileRootPresentationState.WorkspaceDetailPresentation.allCases)
    func everyWorkspaceDetailPresentationBlocksMigration(
        _ presentation: MobileRootPresentationState.WorkspaceDetailPresentation
    ) {
        var state = MobileRootPresentationState()
        let child = MobileRootPresentationState.ChildPresentation.workspaceDetail(presentation)

        #expect(state.apply(.presentChild(child)) == .none)
        #expect(state.presentation == .child(child))
        #expect(state.apply(.presentAutoConnectMigrationIfIdle) == .none)
        #expect(state.presentation == .child(child))

        #expect(state.apply(.dismissChild(child)) == .none)
        #expect(state.apply(.childDidDismiss(child)) == .retryAutoConnectMigration)
        #expect(state.isIdle)
    }

    @Test func pairingRequestedFromChildWaitsForItsDismissalCallback() {
        var state = MobileRootPresentationState()
        let scanner = PairingPresentation.scanner(entry: .settingsReplay)
        let child = MobileRootPresentationState.ChildPresentation.workspaceList(.settings)
        state.apply(.presentChild(child))

        #expect(state.apply(.presentPairing(scanner)) == .none)
        #expect(
            state.presentation
                == .dismissingChild(child, pendingPairing: scanner)
        )
        #expect(!state.isRootSheetPresented)

        #expect(state.apply(.childDidDismiss(child)) == .none)
        #expect(state.presentation == .pairing(scanner))
        #expect(state.isRootSheetPresented)
    }

    @Test func authenticationLossDismissesMigrationWithoutAcknowledgingIt() {
        var state = MobileRootPresentationState()
        state.apply(.presentAutoConnectMigrationIfIdle)

        #expect(state.apply(.authenticationChanged(isAuthenticated: false)) == .none)
        #expect(state.isIdle)

        #expect(state.apply(.authenticationChanged(isAuthenticated: true)) == .none)
        #expect(state.apply(.presentAutoConnectMigrationIfIdle) == .none)
        #expect(state.presentation == .autoConnectMigrationIntroduction)
    }

    @Test func onboardingRegressionDismissesMigrationWithoutAcknowledgingIt() {
        var state = MobileRootPresentationState()
        state.apply(.presentAutoConnectMigrationIfIdle)

        #expect(state.apply(.migrationEligibilityChanged(isEligible: false)) == .none)
        #expect(state.isIdle)

        #expect(state.apply(.migrationEligibilityChanged(isEligible: true)) == .none)
        #expect(state.apply(.presentAutoConnectMigrationIfIdle) == .none)
        #expect(state.presentation == .autoConnectMigrationIntroduction)
    }

    @Test func authenticationLossFinishesActivePairing() {
        var state = MobileRootPresentationState()
        state.apply(.presentPairing(.manual))

        #expect(
            state.apply(.authenticationChanged(isAuthenticated: false))
                == .finishPairing
        )
        #expect(state.isIdle)
    }

    @Test func connectionSuccessDismissesOnlyPairing() {
        var state = MobileRootPresentationState()
        state.apply(.presentAutoConnectMigrationIfIdle)

        #expect(state.apply(.dismissPairing) == .none)
        #expect(state.presentation == .autoConnectMigrationIntroduction)

        state.apply(.presentPairing(.manual))
        #expect(state.apply(.dismissPairing) == .finishPairing)
        #expect(state.presentation == nil)
    }
}
