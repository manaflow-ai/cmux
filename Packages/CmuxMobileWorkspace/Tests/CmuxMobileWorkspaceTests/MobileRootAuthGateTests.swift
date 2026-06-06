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
}
