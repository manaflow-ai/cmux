import CMUXMobileCore
import Testing
@testable import CmuxMobileTerminalKit

@Test func primaryScrollUsesLocalMirrorOnlyWhenHydrated() {
    let policy = MobileTerminalScrollForwardingPolicy()

    let unhydrated = policy.decision(
        activeScreen: .primary,
        decouplePrimaryScreenScroll: true,
        localMirrorCanServePrimaryScroll: false,
        localMirrorRequiresHydration: true
    )
    #expect(unhydrated.appliesLocally == false)
    #expect(unhydrated.forwardsToHost)
    #expect(unhydrated.requestsScrollbackHydration)

    let hydrated = policy.decision(
        activeScreen: .primary,
        decouplePrimaryScreenScroll: true,
        localMirrorCanServePrimaryScroll: true,
        localMirrorRequiresHydration: false
    )
    #expect(hydrated.appliesLocally)
    #expect(hydrated.forwardsToHost == false)
    #expect(hydrated.requestsScrollbackHydration == false)
}

@Test func primaryScrollHydratesHostAtRetainedMirrorEdge() {
    let decision = MobileTerminalScrollForwardingPolicy().decision(
        activeScreen: .primary,
        decouplePrimaryScreenScroll: true,
        localMirrorCanServePrimaryScroll: true,
        localMirrorRequiresHydration: false,
        localMirrorRequestsMoreScrollback: true
    )

    #expect(decision.appliesLocally)
    #expect(decision.forwardsToHost)
    #expect(decision.requestsScrollbackHydration)
    #expect(decision.hostScrollLines(forGestureLines: 4.5) == 0)
}

@Test func alternateScreenScrollAlwaysForwardsWithoutHistoryHydration() {
    let decision = MobileTerminalScrollForwardingPolicy().decision(
        activeScreen: .alternate,
        decouplePrimaryScreenScroll: true,
        localMirrorCanServePrimaryScroll: true,
        localMirrorRequiresHydration: false
    )

    #expect(decision.appliesLocally == false)
    #expect(decision.forwardsToHost)
    #expect(decision.requestsScrollbackHydration == false)
    #expect(decision.hostScrollLines(forGestureLines: -2) == -2)
}

@Test func unhydratedPrimaryScrollForwardsGestureDeltaWhileRequestingHydration() {
    let decision = MobileTerminalScrollForwardingPolicy().decision(
        activeScreen: .primary,
        decouplePrimaryScreenScroll: true,
        localMirrorCanServePrimaryScroll: false,
        localMirrorRequiresHydration: true
    )

    #expect(decision.appliesLocally == false)
    #expect(decision.forwardsToHost)
    #expect(decision.requestsScrollbackHydration)
    #expect(decision.hostScrollLines(forGestureLines: 3) == 3)
}
