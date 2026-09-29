import Testing

@testable import CmuxMobileTerminal

@Suite("Terminal scroll gesture route")
struct TerminalScrollGestureRouteTests {
    @Test("primary pixel ownership survives a transient screen update")
    func primaryOwnershipSurvivesTransientUpdate() {
        var route = TerminalScrollGestureRoute()
        route.begin()

        #expect(route.resolve(
            currentAuthority: .legacyMirror,
            currentOwnsLocalPrimaryScreen: true
        ).usesPixelPath)

        #expect(route.resolve(
            currentAuthority: .verifiedRenderGrid,
            currentOwnsLocalPrimaryScreen: false
        ).usesPixelPath)
    }

    @Test("a route that starts before primary confirmation can claim pixels later")
    func primaryOwnershipCanArriveAfterRouteCapture() {
        var route = TerminalScrollGestureRoute()
        route.begin()

        #expect(!route.resolve(
            currentAuthority: .legacyMirror,
            currentOwnsLocalPrimaryScreen: false
        ).usesPixelPath)
        #expect(route.resolve(
            currentAuthority: .legacyMirror,
            currentOwnsLocalPrimaryScreen: true
        ).usesPixelPath)
    }

    @Test("verified replay remains authoritative for the whole gesture")
    func verifiedReplayDoesNotSwitchToLocalPixels() {
        var route = TerminalScrollGestureRoute()
        route.begin()

        #expect(!route.resolve(
            currentAuthority: .verifiedRenderGrid,
            currentOwnsLocalPrimaryScreen: true
        ).usesPixelPath)
        #expect(!route.resolve(
            currentAuthority: .legacyMirror,
            currentOwnsLocalPrimaryScreen: true
        ).usesPixelPath)
    }

    @Test("a new gesture drops the prior ownership claim")
    func newGestureStartsUnclaimed() {
        var route = TerminalScrollGestureRoute()
        route.begin()
        #expect(route.resolve(
            currentAuthority: .legacyMirror,
            currentOwnsLocalPrimaryScreen: true
        ).usesPixelPath)

        route.begin()
        #expect(!route.resolve(
            currentAuthority: .legacyMirror,
            currentOwnsLocalPrimaryScreen: false
        ).usesPixelPath)
    }
}
