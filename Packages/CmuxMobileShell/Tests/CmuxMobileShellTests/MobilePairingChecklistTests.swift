import CMUXMobileCore
import CmuxMobileRPC
import CmuxMobileShellModel
import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileShell

/// Tests the pure projection from a classified pairing failure to the three
/// network / authentication / trust check marks (issue #6084). Every failure
/// resolves to exactly one failed gate, the gates it provably cleared show a
/// check, and the rest stay untested — verified without a live connection.
@Suite struct MobilePairingChecklistTests {
    // MARK: - Stage assignment

    @Test func everyNonCancelledCategoryHasAStage() throws {
        let categories: [MobilePairingFailureCategory] = [
            .offline,
            .hostUnreachable(host: "h", port: 1),
            .listenerNotRunning(host: "h", port: 1),
            .localNetworkBlocked,
            .dnsFailed(host: "h", port: 1),
            .handshakeTimedOut(host: "h", port: 1),
            .connectionDropped(host: "h", port: 1),
            .accountMismatch,
            .authFailed,
            .ticketExpired,
            .invalidCode,
            .loopbackRejected,
            .unsupportedRoute,
            .noSupportedRoute,
            .unknown(host: "h", port: 1),
        ]
        for category in categories {
            #expect(category.stage != nil, "category \(category) must map to a gate")
        }
    }

    @Test func cancelledHasNoStage() {
        #expect(MobilePairingFailureCategory.cancelled.stage == nil)
    }

    @Test func reachabilityFailuresAreNetworkStage() {
        let networkCategories: [MobilePairingFailureCategory] = [
            .offline,
            .hostUnreachable(host: "h", port: 1),
            .listenerNotRunning(host: "h", port: 1),
            .localNetworkBlocked,
            .dnsFailed(host: "h", port: 1),
            .handshakeTimedOut(host: "h", port: 1),
            .connectionDropped(host: "h", port: 1),
            .invalidCode,
            .loopbackRejected,
            .noSupportedRoute,
            .unknown(host: "h", port: 1),
        ]
        for category in networkCategories {
            #expect(category.stage == .network, "\(category) should be a network-gate failure")
        }
    }

    @Test func credentialFailuresAreAuthenticationStage() {
        #expect(MobilePairingFailureCategory.authFailed.stage == .authentication)
        #expect(MobilePairingFailureCategory.ticketExpired.stage == .authentication)
    }

    @Test func accountAndRouteFailuresAreTrustStage() {
        #expect(MobilePairingFailureCategory.accountMismatch.stage == .trust)
        #expect(MobilePairingFailureCategory.unsupportedRoute.stage == .trust)
    }

    @Test func onlyOnWireAuthFailuresClearPriorGates() {
        #expect(MobilePairingFailureCategory.authFailed.clearsPriorGates)
        #expect(MobilePairingFailureCategory.ticketExpired.clearsPriorGates)
        #expect(MobilePairingFailureCategory.accountMismatch.clearsPriorGates)
        // Pre-transport and route-refused failures prove nothing about earlier gates.
        #expect(!MobilePairingFailureCategory.offline.clearsPriorGates)
        #expect(!MobilePairingFailureCategory.hostUnreachable(host: "h", port: 1).clearsPriorGates)
        #expect(!MobilePairingFailureCategory.unsupportedRoute.clearsPriorGates)
        #expect(!MobilePairingFailureCategory.invalidCode.clearsPriorGates)
    }

    // MARK: - Resolved checklist

    @Test func offlineFailsNetworkAndLeavesLaterGatesUntested() {
        let category = MobilePairingFailureCategory.offline
        let checklist = MobilePairingChecklist.resolving(category)
        #expect(checklist.network == .failed(message: category.message, guidance: category.guidance))
        #expect(checklist.authentication == .pending)
        #expect(checklist.trust == .pending)
        #expect(checklist.failedStage == .network)
    }

    @Test func authFailureClearsNetworkAndLeavesTrustUntested() {
        let category = MobilePairingFailureCategory.authFailed
        let checklist = MobilePairingChecklist.resolving(category)
        #expect(checklist.network == .succeeded)
        #expect(checklist.authentication == .failed(message: category.message, guidance: category.guidance))
        #expect(checklist.trust == .pending)
        #expect(checklist.failedStage == .authentication)
    }

    @Test func ticketExpiredFailsAuthenticationGate() {
        let category = MobilePairingFailureCategory.ticketExpired
        let checklist = MobilePairingChecklist.resolving(category)
        #expect(checklist.network == .succeeded)
        #expect(checklist.authentication.isFailed)
        #expect(checklist.trust == .pending)
    }

    @Test func accountMismatchClearsNetworkAndAuthThenFailsTrust() {
        let category = MobilePairingFailureCategory.accountMismatch
        let checklist = MobilePairingChecklist.resolving(category)
        #expect(checklist.network == .succeeded)
        #expect(checklist.authentication == .succeeded)
        #expect(checklist.trust == .failed(message: category.message, guidance: category.guidance))
        #expect(checklist.failedStage == .trust)
    }

    @Test func untrustedRouteFailsTrustWithoutClaimingEarlierGates() {
        // A route refused client-side never reaches the Mac, so the earlier gates
        // stay untested even though trust is the failed gate.
        let category = MobilePairingFailureCategory.unsupportedRoute
        let checklist = MobilePairingChecklist.resolving(category)
        #expect(checklist.network == .pending)
        #expect(checklist.authentication == .pending)
        #expect(checklist.trust == .failed(message: category.message, guidance: category.guidance))
    }

    @Test func invalidCodeFailsNetworkGate() {
        let category = MobilePairingFailureCategory.invalidCode
        let checklist = MobilePairingChecklist.resolving(category)
        #expect(checklist.network.isFailed)
        #expect(checklist.authentication == .pending)
        #expect(checklist.trust == .pending)
    }

    // MARK: - Static snapshots and helpers

    @Test func connectingChecklistAttemptsNetworkFirst() {
        let checklist = MobilePairingChecklist.connecting
        #expect(checklist.network == .inProgress)
        #expect(checklist.authentication == .pending)
        #expect(checklist.trust == .pending)
        #expect(checklist.isInProgress)
        #expect(checklist.failedStage == nil)
    }

    @Test func connectedChecklistClearsEveryGate() {
        let checklist = MobilePairingChecklist.connected
        for stage in MobilePairingStage.allCases {
            #expect(checklist.status(for: stage) == .succeeded)
        }
        #expect(!checklist.isInProgress)
        #expect(checklist.failedStage == nil)
    }

    @Test func stageAccessorMatchesStoredStatuses() {
        let checklist = MobilePairingChecklist(
            network: .succeeded,
            authentication: .inProgress,
            trust: .pending
        )
        #expect(checklist.status(for: .network) == .succeeded)
        #expect(checklist.status(for: .authentication) == .inProgress)
        #expect(checklist.status(for: .trust) == .pending)
    }
}
