import Testing

@testable import CmuxMobileShellUI

@Suite("Root sheet presentation state")
struct MobileRootPresentationStateTests {
    @Test func introductionRoutesThroughSettingsAndPairingWithoutDismissal() {
        var state = MobileRootPresentationState()

        #expect(state.apply(.presentAutoConnectMigrationIfIdle) == .none)
        #expect(state.presentation == .autoConnectMigrationIntroduction)
        #expect(state.isRootSheetPresented)

        #expect(state.apply(.openConnectionSettings) == .acknowledgeAutoConnectMigration)
        #expect(state.presentation == .connectionSettings)
        #expect(state.isRootSheetPresented)

        let scanner = PairingPresentation.scanner(entry: .settingsReplay)
        #expect(state.apply(.presentPairing(scanner)) == .none)
        #expect(state.presentation == .pairing(scanner))
        #expect(state.isRootSheetPresented)
    }

    @Test func interactiveIntroductionDismissalRequestsAcknowledgement() {
        var state = MobileRootPresentationState()
        state.apply(.presentAutoConnectMigrationIfIdle)

        #expect(state.apply(.sheetDidRequestDismissal) == .acknowledgeAutoConnectMigration)
        #expect(state.presentation == nil)
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

    @Test func childModalBlocksMigrationUntilItsDismissalCompletes() {
        var state = MobileRootPresentationState()

        #expect(state.apply(.presentChild(.shellSettings)) == .none)
        #expect(state.presentation == .child(.shellSettings))
        #expect(state.isPresentingChild(.shellSettings))

        #expect(state.apply(.presentAutoConnectMigrationIfIdle) == .none)
        #expect(state.presentation == .child(.shellSettings))

        #expect(state.apply(.dismissChild(.shellSettings)) == .none)
        #expect(
            state.presentation
                == .dismissingChild(.shellSettings, pendingPairing: nil)
        )
        #expect(!state.isPresentingChild(.shellSettings))
        #expect(!state.isIdle)
        #expect(state.apply(.presentAutoConnectMigrationIfIdle) == .none)
        #expect(
            state.presentation
                == .dismissingChild(.shellSettings, pendingPairing: nil)
        )

        #expect(
            state.apply(.childDidDismiss(.shellSettings))
                == .retryAutoConnectMigration
        )
        #expect(state.isIdle)

        #expect(state.apply(.presentAutoConnectMigrationIfIdle) == .none)
        #expect(state.presentation == .autoConnectMigrationIntroduction)
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
        state.apply(.presentChild(.shellSettings))

        #expect(state.apply(.presentPairing(scanner)) == .none)
        #expect(
            state.presentation
                == .dismissingChild(.shellSettings, pendingPairing: scanner)
        )
        #expect(!state.isRootSheetPresented)

        #expect(state.apply(.childDidDismiss(.shellSettings)) == .none)
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
