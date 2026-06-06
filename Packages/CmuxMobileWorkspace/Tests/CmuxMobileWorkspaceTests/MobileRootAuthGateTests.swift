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
        let authURL = try #require(URL(string: "stack-auth-mobile-oauth-url://callback?code=test"))
        let otherURL = try #require(URL(string: "cmux-ios://oauth?v=1"))

        #expect(MobileRootAuthGate.isAttachURL(attachURL))
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
            connectionState: .disconnected
        ))
        #expect(!MobileRootAuthGate.shouldReconnectStoredMac(
            stackAuthenticated: true,
            attachTicketAuthenticated: true,
            connectionState: .disconnected
        ))
        #expect(!MobileRootAuthGate.shouldReconnectStoredMac(
            stackAuthenticated: false,
            attachTicketAuthenticated: true,
            connectionState: .disconnected
        ))
    }

    @Test func showsRestoringStoredMacWhileReconnectingAKnownPairedMac() {
        // Actively reconnecting a found stored Mac.
        #expect(MobileRootAuthGate.shouldShowRestoringStoredMac(
            authenticated: true,
            connectionState: .disconnected,
            isReconnectingStoredMac: true,
            hasKnownPairedMac: false,
            didFinishStoredMacReconnectAttempt: false
        ))
        // First frame for a returning user: persisted hint, attempt not yet resolved.
        #expect(MobileRootAuthGate.shouldShowRestoringStoredMac(
            authenticated: true,
            connectionState: .disconnected,
            isReconnectingStoredMac: false,
            hasKnownPairedMac: true,
            didFinishStoredMacReconnectAttempt: false
        ))
        // Failed/offline attempt resolved: fall through to the add-device view.
        #expect(!MobileRootAuthGate.shouldShowRestoringStoredMac(
            authenticated: true,
            connectionState: .disconnected,
            isReconnectingStoredMac: false,
            hasKnownPairedMac: true,
            didFinishStoredMacReconnectAttempt: true
        ))
        // Never paired: add-device immediately, no restoring flash.
        #expect(!MobileRootAuthGate.shouldShowRestoringStoredMac(
            authenticated: true,
            connectionState: .disconnected,
            isReconnectingStoredMac: false,
            hasKnownPairedMac: false,
            didFinishStoredMacReconnectAttempt: false
        ))
        // Already connected: never show the restoring UI, regardless of flags.
        #expect(!MobileRootAuthGate.shouldShowRestoringStoredMac(
            authenticated: true,
            connectionState: .connected,
            isReconnectingStoredMac: true,
            hasKnownPairedMac: true,
            didFinishStoredMacReconnectAttempt: false
        ))
        // Not authenticated: the sign-in/restoring-session gates run instead.
        #expect(!MobileRootAuthGate.shouldShowRestoringStoredMac(
            authenticated: false,
            connectionState: .disconnected,
            isReconnectingStoredMac: true,
            hasKnownPairedMac: true,
            didFinishStoredMacReconnectAttempt: false
        ))
    }
}
