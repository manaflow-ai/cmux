import Testing
@testable import CmuxTerminalCore

// (B) serial-granularity fix (impl-B-serial-fix): `TerminalHoverIndicatorOwner`
// no longer carries transition logic of its own — see its updated doc.
// Every scenario this suite previously covered (native/external ordering,
// displacement, deactivation-match rules, out-of-order task delivery) now
// lives on `TerminalHoverIndicatorState` and is covered by
// `TerminalHoverIndicatorStateTests`. This suite is left only to confirm
// the bare enum's identity/`Equatable` behavior, which the reducer relies
// on for its own `guard case .external(...) == ...` matching.
@Suite("TerminalHoverIndicatorOwner")
struct TerminalHoverIndicatorOwnerTests {
    private static func token(_ seed: UInt64) -> HoverActivationTokenValue {
        HoverActivationTokenValue(bits: (seed, seed &+ 1, seed &+ 2, seed &+ 3))
    }

    @Test("External owners are equal only when both event and token match")
    func externalEqualityRequiresBothEventAndToken() {
        let owner = TerminalHoverIndicatorOwner.external(hoverEventID: 1, token: Self.token(1))
        #expect(owner == .external(hoverEventID: 1, token: Self.token(1)))
        #expect(owner != .external(hoverEventID: 2, token: Self.token(1)))
        #expect(owner != .external(hoverEventID: 1, token: Self.token(2)))
        #expect(owner != .native(hoverEventID: 1))
        #expect(owner != .none)
    }
}
