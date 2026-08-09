import Testing
@testable import CmuxTerminalCore

@Suite("TerminalHoverIndicatorOwner")
struct TerminalHoverIndicatorOwnerTests {
    private static func token(_ seed: UInt64) -> HoverActivationTokenValue {
        HoverActivationTokenValue(bits: (seed, seed &+ 1, seed &+ 2, seed &+ 3))
    }

    @Test("A native result for a fresh event installs native")
    func nativeResultInstallsNative() {
        let owner = TerminalHoverIndicatorOwner.none
            .receivingNativeResult(hoverEventID: 1, url: "https://example.com")
        #expect(owner == .native(hoverEventID: 1))
    }

    @Test("A native no-URL result for the currently-displayed event clears to none")
    func nativeNoURLClearsCurrentEvent() {
        let owner = TerminalHoverIndicatorOwner.native(hoverEventID: 1)
            .receivingNativeResult(hoverEventID: 1, url: nil)
        #expect(owner == .none)
    }

    @Test("A stale native no-URL result for an older event does not clear a newer native display")
    func staleNativeNoURLDoesNotClearNewerEvent() {
        let owner = TerminalHoverIndicatorOwner.native(hoverEventID: 2)
            .receivingNativeResult(hoverEventID: 1, url: nil)
        #expect(owner == .native(hoverEventID: 2))
    }

    @Test("External-active for the same event a native result later arrives for is never displaced")
    func externalActiveNeverDisplacedBySameEventNativeResult() {
        let owner = TerminalHoverIndicatorOwner.external(hoverEventID: 1, token: Self.token(1))
            .receivingNativeResult(hoverEventID: 1, url: "https://example.com")
        #expect(owner == .external(hoverEventID: 1, token: Self.token(1)))
    }

    @Test("A native result for a newer event than the current external owner takes over")
    func nativeResultForNewerEventTakesOverFromExternal() {
        let owner = TerminalHoverIndicatorOwner.external(hoverEventID: 1, token: Self.token(1))
            .receivingNativeResult(hoverEventID: 2, url: "https://example.com")
        #expect(owner == .native(hoverEventID: 2))
    }

    @Test("External activation always replaces whatever was displayed")
    func externalActivationAlwaysReplaces() {
        let fromNative = TerminalHoverIndicatorOwner.native(hoverEventID: 1)
            .receivingExternalActive(hoverEventID: 1, token: Self.token(1))
        #expect(fromNative == .external(hoverEventID: 1, token: Self.token(1)))

        let fromNone = TerminalHoverIndicatorOwner.none
            .receivingExternalActive(hoverEventID: 2, token: Self.token(2))
        #expect(fromNone == .external(hoverEventID: 2, token: Self.token(2)))
    }

    @Test("External deactivation only clears an exact event+token match")
    func externalDeactivationOnlyClearsExactMatch() {
        let owner = TerminalHoverIndicatorOwner.external(hoverEventID: 1, token: Self.token(1))

        let mismatchedEvent = owner.receivingExternalInactive(hoverEventID: 2, token: Self.token(1))
        #expect(mismatchedEvent == owner)

        let mismatchedToken = owner.receivingExternalInactive(hoverEventID: 1, token: Self.token(2))
        #expect(mismatchedToken == owner)

        let exactMatch = owner.receivingExternalInactive(hoverEventID: 1, token: Self.token(1))
        #expect(exactMatch == .none)
    }

    @Test("External deactivation for a token that was already replaced by a newer owner is a no-op")
    func externalDeactivationForReplacedOwnerIsNoOp() {
        let replaced = TerminalHoverIndicatorOwner.external(hoverEventID: 2, token: Self.token(2))
        let result = replaced.receivingExternalInactive(hoverEventID: 1, token: Self.token(1))
        #expect(result == replaced)
    }
}
