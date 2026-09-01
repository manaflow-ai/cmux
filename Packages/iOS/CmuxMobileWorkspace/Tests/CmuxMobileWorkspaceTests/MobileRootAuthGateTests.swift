import Foundation
import Testing

@testable import CmuxMobileWorkspace

@Suite struct MobileRootAuthGateTests {
    @Test func allowsAttachTicketAuthenticationWithoutStackAuth() throws {
        #expect(MobileRootAuthGate.isAuthenticated(
            stackAuthenticated: false,
            attachTicketAuthenticated: true
        ))
        #expect(!MobileRootAuthGate.isAuthenticated(
            stackAuthenticated: false,
            attachTicketAuthenticated: false
        ))

        let attachURL = try #require(URL(string: "cmux-ios://attach?v=1&payload=test"))
        // The dev channel's scheme is also a valid attach deep link, so a dev
        // build recognizes the deep link the system camera hands it.
        let devAttachURL = try #require(URL(string: "cmux-ios-dev://attach?v=2&r=100.64.0.5:58465"))
        let authURL = try #require(URL(string: "stack-auth-mobile-oauth-url://callback?code=test"))
        let otherURL = try #require(URL(string: "cmux-ios://oauth?v=1"))

        #expect(MobileRootAuthGate.isAttachURL(attachURL))
        #expect(MobileRootAuthGate.isAttachURL(devAttachURL))
        #expect(!MobileRootAuthGate.isAttachURL(authURL))
        #expect(!MobileRootAuthGate.isAttachURL(otherURL))
    }

    @Test func showsRestoringSessionOnlyBeforeAuthentication() {
        #expect(MobileRootAuthGate.shouldShowRestoringSession(
            stackAuthenticated: false,
            attachTicketAuthenticated: false,
            isRestoringSession: true
        ))
        #expect(!MobileRootAuthGate.shouldShowRestoringSession(
            stackAuthenticated: true,
            attachTicketAuthenticated: false,
            isRestoringSession: true
        ))
        #expect(!MobileRootAuthGate.shouldShowRestoringSession(
            stackAuthenticated: false,
            attachTicketAuthenticated: true,
            isRestoringSession: true
        ))
        #expect(!MobileRootAuthGate.shouldShowRestoringSession(
            stackAuthenticated: false,
            attachTicketAuthenticated: false,
            isRestoringSession: false
        ))
    }

    @Test func clearsOnlyStaleTemporaryAttachAuthentication() {
        #expect(MobileRootAuthGate.shouldClearAttachTicketAuthentication(
            pairingResult: .failed,
            connectionState: .disconnected,
            hasActiveUnexpiredTicket: false
        ))
        #expect(MobileRootAuthGate.shouldClearAttachTicketAuthentication(
            pairingResult: .superseded,
            connectionState: .disconnected,
            hasActiveUnexpiredTicket: false
        ))
        #expect(!MobileRootAuthGate.shouldClearAttachTicketAuthentication(
            pairingResult: .needsUserApproval,
            connectionState: .disconnected,
            hasActiveUnexpiredTicket: false
        ))
        #expect(!MobileRootAuthGate.shouldClearAttachTicketAuthentication(
            pairingResult: .superseded,
            connectionState: .connected,
            hasActiveUnexpiredTicket: true
        ))
        #expect(!MobileRootAuthGate.shouldClearAttachTicketAuthentication(
            pairingResult: .connected,
            connectionState: .connected,
            hasActiveUnexpiredTicket: true
        ))
        #expect(MobileRootAuthGate.shouldClearAttachTicketAuthentication(
            pairingResult: .connected,
            connectionState: .connected,
            hasActiveUnexpiredTicket: false
        ))
        #expect(MobileRootAuthGate.shouldReconnectStoredMac(
            stackAuthenticated: true,
            attachTicketAuthenticated: false,
            didFinishAuthBootstrap: true,
            isRestoringSession: false,
            hasRestoredAccountIdentity: true,
            connectionState: .disconnected
        ))
        #expect(!MobileRootAuthGate.shouldReconnectStoredMac(
            stackAuthenticated: true,
            attachTicketAuthenticated: true,
            didFinishAuthBootstrap: true,
            isRestoringSession: false,
            hasRestoredAccountIdentity: true,
            connectionState: .disconnected
        ))
        #expect(!MobileRootAuthGate.shouldReconnectStoredMac(
            stackAuthenticated: false,
            attachTicketAuthenticated: true,
            didFinishAuthBootstrap: true,
            isRestoringSession: false,
            hasRestoredAccountIdentity: true,
            connectionState: .disconnected
        ))
        #expect(!MobileRootAuthGate.shouldReconnectStoredMac(
            stackAuthenticated: true,
            attachTicketAuthenticated: false,
            didFinishAuthBootstrap: true,
            isRestoringSession: true,
            hasRestoredAccountIdentity: true,
            connectionState: .disconnected
        ))
        #expect(!MobileRootAuthGate.shouldReconnectStoredMac(
            stackAuthenticated: true,
            attachTicketAuthenticated: false,
            didFinishAuthBootstrap: false,
            isRestoringSession: false,
            hasRestoredAccountIdentity: true,
            connectionState: .disconnected
        ))
    }

    @Test func dialsEarlyOnlyForARestoredSessionWithAReadableIdentity() {
        // Launch restore of a keychain session with a readable cached user id:
        // the dial overlaps the auth bootstrap instead of waiting behind it.
        #expect(MobileRootAuthGate.shouldReconnectStoredMac(
            stackAuthenticated: true,
            attachTicketAuthenticated: false,
            didFinishAuthBootstrap: false,
            isRestoringSession: true,
            hasRestoredAccountIdentity: true,
            connectionState: .disconnected
        ))
        // No readable restored identity: the account scope cannot be pinned,
        // so the dial waits for the bootstrap verdict.
        #expect(!MobileRootAuthGate.shouldReconnectStoredMac(
            stackAuthenticated: true,
            attachTicketAuthenticated: false,
            didFinishAuthBootstrap: false,
            isRestoringSession: true,
            hasRestoredAccountIdentity: false,
            connectionState: .disconnected
        ))
        // A temporary attach ticket still owns the connection during restore.
        #expect(!MobileRootAuthGate.shouldReconnectStoredMac(
            stackAuthenticated: true,
            attachTicketAuthenticated: true,
            didFinishAuthBootstrap: false,
            isRestoringSession: true,
            hasRestoredAccountIdentity: true,
            connectionState: .disconnected
        ))
        // Already connected: nothing to dial.
        #expect(!MobileRootAuthGate.shouldReconnectStoredMac(
            stackAuthenticated: true,
            attachTicketAuthenticated: false,
            didFinishAuthBootstrap: false,
            isRestoringSession: true,
            hasRestoredAccountIdentity: true,
            connectionState: .connected
        ))
        // Restoring without published stack auth (no cached user at priming).
        #expect(!MobileRootAuthGate.shouldReconnectStoredMac(
            stackAuthenticated: false,
            attachTicketAuthenticated: false,
            didFinishAuthBootstrap: false,
            isRestoringSession: true,
            hasRestoredAccountIdentity: false,
            connectionState: .disconnected
        ))
    }

    @Test func startsStartupConnectionsAfterBootstrapOrDuringRestoredSessionRestore() {
        // Classic post-bootstrap barrier.
        #expect(MobileRootAuthGate.shouldStartStartupConnections(
            stackAuthenticated: true,
            attachTicketAuthenticated: false,
            didFinishAuthBootstrap: true,
            isRestoringSession: false,
            hasRestoredAccountIdentity: true
        ))
        // Early launch window against the restored keychain session.
        #expect(MobileRootAuthGate.shouldStartStartupConnections(
            stackAuthenticated: true,
            attachTicketAuthenticated: false,
            didFinishAuthBootstrap: false,
            isRestoringSession: true,
            hasRestoredAccountIdentity: true
        ))
        // Restored session with no readable id keeps waiting for bootstrap.
        #expect(!MobileRootAuthGate.shouldStartStartupConnections(
            stackAuthenticated: true,
            attachTicketAuthenticated: false,
            didFinishAuthBootstrap: false,
            isRestoringSession: true,
            hasRestoredAccountIdentity: false
        ))
        // Interactive sign-in published before the bootstrap barrier: startup
        // still waits for the team scope the bootstrap continuation applies.
        #expect(!MobileRootAuthGate.shouldStartStartupConnections(
            stackAuthenticated: true,
            attachTicketAuthenticated: false,
            didFinishAuthBootstrap: false,
            isRestoringSession: false,
            hasRestoredAccountIdentity: true
        ))
        // Attach-ticket-only authentication starts nothing before bootstrap
        // (the ticket, not startup, owns the connection) but passes the
        // composite gate after it, matching the pre-early-dial behavior.
        #expect(!MobileRootAuthGate.shouldStartStartupConnections(
            stackAuthenticated: false,
            attachTicketAuthenticated: true,
            didFinishAuthBootstrap: false,
            isRestoringSession: true,
            hasRestoredAccountIdentity: false
        ))
        #expect(MobileRootAuthGate.shouldStartStartupConnections(
            stackAuthenticated: false,
            attachTicketAuthenticated: true,
            didFinishAuthBootstrap: true,
            isRestoringSession: false,
            hasRestoredAccountIdentity: false
        ))
        // Signed out entirely.
        #expect(!MobileRootAuthGate.shouldStartStartupConnections(
            stackAuthenticated: false,
            attachTicketAuthenticated: false,
            didFinishAuthBootstrap: true,
            isRestoringSession: false,
            hasRestoredAccountIdentity: false
        ))
    }

    @Test func showsRestoringStoredMacWhileReconnectingAKnownPairedMac() {
        // Actively reconnecting a found stored Mac.
        #expect(MobileRootAuthGate.shouldShowRestoringStoredMac(
            authenticated: true,
            connectionState: .disconnected,
            isReconnectingStoredMac: true,
            hasKnownPairedMac: false,
            pairedMacHintUndetermined: false,
            didFinishStoredMacReconnectAttempt: false
        ))
        // First frame for a returning user: persisted hint, attempt not yet resolved.
        #expect(MobileRootAuthGate.shouldShowRestoringStoredMac(
            authenticated: true,
            connectionState: .disconnected,
            isReconnectingStoredMac: false,
            hasKnownPairedMac: true,
            pairedMacHintUndetermined: false,
            didFinishStoredMacReconnectAttempt: false
        ))
        // Existing install that predates the hint (key absent): treat undetermined
        // as "may have a paired Mac" so it does not flash add-device on first launch.
        #expect(MobileRootAuthGate.shouldShowRestoringStoredMac(
            authenticated: true,
            connectionState: .disconnected,
            isReconnectingStoredMac: false,
            hasKnownPairedMac: false,
            pairedMacHintUndetermined: true,
            didFinishStoredMacReconnectAttempt: false
        ))
        // Undetermined, but the first attempt resolved with no Mac: fall through.
        #expect(!MobileRootAuthGate.shouldShowRestoringStoredMac(
            authenticated: true,
            connectionState: .disconnected,
            isReconnectingStoredMac: false,
            hasKnownPairedMac: false,
            pairedMacHintUndetermined: true,
            didFinishStoredMacReconnectAttempt: true
        ))
        // Failed/offline attempt resolved: fall through to the add-device view.
        #expect(!MobileRootAuthGate.shouldShowRestoringStoredMac(
            authenticated: true,
            connectionState: .disconnected,
            isReconnectingStoredMac: false,
            hasKnownPairedMac: true,
            pairedMacHintUndetermined: false,
            didFinishStoredMacReconnectAttempt: true
        ))
        // A later runtime redial must keep the established workspace shell
        // mounted. Re-entering the launch-only restoring branch destroys the
        // shell's compact navigation path and returns the user to the list.
        #expect(!MobileRootAuthGate.shouldShowRestoringStoredMac(
            authenticated: true,
            connectionState: .disconnected,
            isReconnectingStoredMac: true,
            hasKnownPairedMac: true,
            pairedMacHintUndetermined: false,
            didFinishStoredMacReconnectAttempt: true
        ))
        // Never paired (hint determined-false): add-device immediately, no flash.
        #expect(!MobileRootAuthGate.shouldShowRestoringStoredMac(
            authenticated: true,
            connectionState: .disconnected,
            isReconnectingStoredMac: false,
            hasKnownPairedMac: false,
            pairedMacHintUndetermined: false,
            didFinishStoredMacReconnectAttempt: false
        ))
        // Already connected: never show the restoring UI, regardless of flags.
        #expect(!MobileRootAuthGate.shouldShowRestoringStoredMac(
            authenticated: true,
            connectionState: .connected,
            isReconnectingStoredMac: true,
            hasKnownPairedMac: true,
            pairedMacHintUndetermined: true,
            didFinishStoredMacReconnectAttempt: false
        ))
        // Not authenticated: the sign-in/restoring-session gates run instead.
        #expect(!MobileRootAuthGate.shouldShowRestoringStoredMac(
            authenticated: false,
            connectionState: .disconnected,
            isReconnectingStoredMac: true,
            hasKnownPairedMac: true,
            pairedMacHintUndetermined: true,
            didFinishStoredMacReconnectAttempt: false
        ))
    }
}
