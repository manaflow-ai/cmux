import Foundation
import Testing
@testable import CmuxMobileShell

// The inline notification reply lane: a reply submitted from the lock screen
// wakes the app in the BACKGROUND, where `suspendForegroundRefresh()` has
// already run. Every automatic recovery trigger parks in that state, which is
// exactly what stranded lock-screen replies until they expired. The
// `.backgroundNotificationReply` trigger — kicked by the push coordinator
// while it holds a background task assertion — must pass the gate instead.

@MainActor
@Test func backgroundReplyRecoveryIsNotParkedWhileBackgrounded() async throws {
    let router = LivenessHostRouter()
    let box = TransportBox()
    let clock = TestClock()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)

    store.suspendForegroundRefresh()
    store.recoverConnectionForBackgroundNotificationReply(macDeviceID: "test-mac")

    // Passing the gate means the trigger was NOT parked for the next
    // foreground; this preview-harness store (no paired-Mac store) then takes
    // the recovery path's no-store branch, which marks the Mac unavailable.
    #expect(store.pendingInactiveRecoveryTrigger == nil)
    #expect(store.macConnectionStatus == .unavailable)
}

@MainActor
@Test func backgroundReplyRecoveryAcceptsPayloadsWithoutMacClaim() async throws {
    let router = LivenessHostRouter()
    let box = TransportBox()
    let clock = TestClock()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)

    store.suspendForegroundRefresh()
    // Older Mac pushes carry no macDeviceId; they always target the
    // foreground pairing.
    store.recoverConnectionForBackgroundNotificationReply(macDeviceID: nil)

    #expect(store.pendingInactiveRecoveryTrigger == nil)
    #expect(store.macConnectionStatus == .unavailable)
}

@MainActor
@Test func backgroundReplyRecoveryIgnoresRepliesForAnotherMac() async throws {
    let router = LivenessHostRouter()
    let box = TransportBox()
    let clock = TestClock()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)

    store.suspendForegroundRefresh()
    let statusBeforeReply = store.macConnectionStatus
    // Selection-neutral contract: a reply claiming a NON-foreground Mac must
    // not redial (and above all must not switch) the foreground pairing.
    store.recoverConnectionForBackgroundNotificationReply(macDeviceID: "some-other-mac")

    #expect(store.pendingInactiveRecoveryTrigger == nil)
    // No recovery pass ran: the no-store branch that marks the Mac
    // unavailable (see the matching-Mac tests) was never reached.
    #expect(store.macConnectionStatus == statusBeforeReply)
    #expect(store.macConnectionStatus != .unavailable)
}

@MainActor
@Test func automaticRecoveryTriggersStayParkedWhileBackgrounded() async throws {
    let router = LivenessHostRouter()
    let box = TransportBox()
    let clock = TestClock()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)

    store.suspendForegroundRefresh()
    let statusBeforeTrigger = store.macConnectionStatus
    store.recoverMobileConnection(trigger: .foreground)

    // The pre-existing contract for every non-reply trigger: park while
    // backgrounded, replay on the next foreground.
    guard case .foreground? = store.pendingInactiveRecoveryTrigger else {
        Issue.record("expected the foreground trigger to park while backgrounded")
        return
    }
    #expect(store.macConnectionStatus == statusBeforeTrigger)
    #expect(store.macConnectionStatus != .unavailable)
}
