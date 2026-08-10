import Testing

@testable import CmuxMobileShellUI

@Suite("Root sheet presentation state")
struct MobileRootPresentationStateTests {
    @Test func introductionRoutesThroughSettingsAndPairingWithoutDismissal() {
        var state = MobileRootPresentationState()

        #expect(state.apply(.presentAutoConnectMigrationIfIdle) == .none)
        #expect(state.presentation == .autoConnectMigrationIntroduction)
        #expect(state.isPresented)

        #expect(state.apply(.openConnectionSettings) == .acknowledgeAutoConnectMigration)
        #expect(state.presentation == .connectionSettings)
        #expect(state.isPresented)

        let scanner = PairingPresentation.scanner(entry: .settingsReplay)
        #expect(state.apply(.presentPairing(scanner)) == .none)
        #expect(state.presentation == .pairing(scanner))
        #expect(state.isPresented)
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
