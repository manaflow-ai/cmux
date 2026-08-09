import Testing
@testable import CmuxTerminalCore

// (B) serial-granularity fix (impl-B-serial-fix). Fixes a real dogfood
// regression: underline stayed on a full 2-line hard-wrapped path while
// the bottom-left indicator fell back to a 1-line native regex fragment.
// Root cause — `TerminalHoverIndicatorOwner`'s old `receivingNativeResult`
// let a "newer host-event-id" native result displace an active external
// owner, but the host's `hoverEventID` bumps on EVERY event while
// Ghostty's own `hover_input_epoch` only bumps on a cell/eligibility
// change; a single sub-pixel move within the same cell bumped
// `hoverEventID` without Ghostty ever re-validating the token, so the
// resent native result for the SAME cell looked "newer" by event id and
// evicted a still-valid external owner. This suite pins down the 9
// transition-rule tests review-B-serial-granularity.md required,
// entirely at the pure-reducer level (no AppKit needed).
@Suite("TerminalHoverIndicatorState")
struct TerminalHoverIndicatorStateTests {
    private static func token(_ seed: UInt64) -> HoverActivationTokenValue {
        HoverActivationTokenValue(bits: (seed, seed &+ 1, seed &+ 2, seed &+ 3))
    }

    // 1. Real-machine repro: external(N,T) -> same-cell native(N+1,
    // fragment URL) -> visible stays external. This is the exact
    // regression: N+1 looks "newer" by event id, but Ghostty never
    // invalidated T for it, so the fragment must never surface.
    @Test("Same-cell resent native never displaces an active external owner")
    func sameCellResentNativeNeverDisplacesActiveExternal() {
        var state = TerminalHoverIndicatorState()
        state.receiveExternalActive(event: 1, token: Self.token(1), path: "/full/two/line/path.md")

        state.receiveNative(event: 2, url: "https://example.com/fragment")

        #expect(state.displayedOwner == .external(hoverEventID: 1, token: Self.token(1)))
        #expect(state.displayedURL == "/full/two/line/path.md")
    }

    // 2. native-first handoff (Ghostty's actual primary delivery order):
    // external(N,T) -> native(N+1, new URL) -> inactive(T) -> visible is
    // native(N+1, new URL). The suppressed native must be held, not
    // dropped, or the handoff to native/OSC8 goes empty.
    @Test("Native-first handoff: a deferred native promotes on the matching inactive")
    func nativeFirstHandoffPromotesDeferredNativeOnInactive() {
        var state = TerminalHoverIndicatorState()
        state.receiveExternalActive(event: 1, token: Self.token(1), path: "/external/path")
        state.receiveNative(event: 2, url: "https://example.com/new")

        // Still external while the native is only deferred.
        #expect(state.displayedOwner == .external(hoverEventID: 1, token: Self.token(1)))

        state.receiveExternalInactive(event: 1, token: Self.token(1))

        #expect(state.displayedOwner == .native(hoverEventID: 2))
        #expect(state.displayedURL == "https://example.com/new")
        #expect(state.deferredNative == nil)
    }

    // 3. inactive-first handoff (the reverse delivery order): external
    // (N,T) -> inactive(T) -> native(N+1, new URL) converges to the SAME
    // native result via ordinary event ordering, since displayedOwner is
    // already `.none` by the time the native result arrives.
    @Test("Inactive-first handoff converges to the same native result")
    func inactiveFirstHandoffConvergesToSameResult() {
        var state = TerminalHoverIndicatorState()
        state.receiveExternalActive(event: 1, token: Self.token(1), path: "/external/path")
        state.receiveExternalInactive(event: 1, token: Self.token(1))

        #expect(state.displayedOwner == .none)

        state.receiveNative(event: 2, url: "https://example.com/new")

        #expect(state.displayedOwner == .native(hoverEventID: 2))
        #expect(state.displayedURL == "https://example.com/new")
    }

    // 4. nil handoff: external(N,T) -> native(N+1, nil/empty) -> inactive
    // (T) -> none. A deferred "found nothing" result promotes to a clear,
    // not to `.native` with an empty label.
    @Test("A deferred nil/empty native result promotes to none, not to a blank native")
    func deferredNilNativeResultPromotesToNone() {
        var state = TerminalHoverIndicatorState()
        state.receiveExternalActive(event: 1, token: Self.token(1), path: "/external/path")
        state.receiveNative(event: 2, url: nil)
        state.receiveExternalInactive(event: 1, token: Self.token(1))

        #expect(state.displayedOwner == .none)
        #expect(state.displayedURL == nil)

        var stateWithEmptyString = TerminalHoverIndicatorState()
        stateWithEmptyString.receiveExternalActive(event: 1, token: Self.token(1), path: "/external/path")
        stateWithEmptyString.receiveNative(event: 2, url: "")
        stateWithEmptyString.receiveExternalInactive(event: 1, token: Self.token(1))

        #expect(stateWithEmptyString.displayedOwner == .none)
    }

    // 5. B0-3 (the ORIGINAL race this reducer must still prevent):
    // external(N2,T2) -> a late native answering an OLDER event N1 ->
    // external T2 stays, and the stale native isn't even held in
    // `deferredNative` (never eligible to be promoted later either).
    @Test("A native result older than the active external's own mint event is discarded outright")
    func olderNativeResultIsDiscardedOutrightNeverDeferred() {
        var state = TerminalHoverIndicatorState()
        state.receiveExternalActive(event: 2, token: Self.token(2), path: "/external/path")

        state.receiveNative(event: 1, url: "https://example.com/stale")

        #expect(state.displayedOwner == .external(hoverEventID: 2, token: Self.token(2)))
        #expect(state.displayedURL == "/external/path")
        #expect(state.deferredNative == nil)
    }

    // 6. replacement: external(N1,T1) -> deferred native(N2) -> external
    // (N3,T3) -> late inactive(T1) -> still T3. inactive(T3) must not
    // resurrect N2 (which belonged to T1's tenure, not T3's).
    @Test("A new external owner clears the previous owner's deferred native")
    func newExternalOwnerClearsPreviousDeferredNative() {
        var state = TerminalHoverIndicatorState()
        state.receiveExternalActive(event: 1, token: Self.token(1), path: "/t1/path")
        state.receiveNative(event: 2, url: "https://example.com/deferred-under-t1")

        state.receiveExternalActive(event: 3, token: Self.token(3), path: "/t3/path")

        // A stale inactive for the REPLACED owner T1 must not touch T3.
        state.receiveExternalInactive(event: 1, token: Self.token(1))
        #expect(state.displayedOwner == .external(hoverEventID: 3, token: Self.token(3)))
        #expect(state.displayedURL == "/t3/path")

        // The real inactive for T3 must not resurrect N2 — there is
        // nothing deferred under T3's tenure.
        state.receiveExternalInactive(event: 3, token: Self.token(3))
        #expect(state.displayedOwner == .none)
        #expect(state.displayedURL != "https://example.com/deferred-under-t1")
    }

    // 7. "one retry": from this pure reducer's perspective, Ghostty's own
    // bounded-retry ack delivery (`externalHoverAckReducer` in
    // `renderer/Thread.zig`, unmodified by this fix) succeeding on its
    // retry attempt is INDISTINGUISHABLE from succeeding on the first
    // attempt — both are exactly one `receiveExternalInactive` call. This
    // pins that convergence, plus that a duplicate/redelivered inactive
    // for the SAME already-resolved token afterward changes nothing
    // further (the redelivery a retry could itself produce).
    @Test("Convergence after a (possibly retried) inactive delivery is stable under redelivery")
    func convergenceAfterInactiveIsStableUnderRedelivery() {
        var state = TerminalHoverIndicatorState()
        state.receiveExternalActive(event: 1, token: Self.token(1), path: "/external/path")
        state.receiveNative(event: 2, url: "https://example.com/new")

        // The single call this reducer ever sees for "inactive, however
        // many attempts it took upstream to deliver."
        state.receiveExternalInactive(event: 1, token: Self.token(1))
        #expect(state.displayedOwner == .native(hoverEventID: 2))
        #expect(state.displayedURL == "https://example.com/new")

        // A duplicate/redelivered inactive for the same (now-stale)
        // token must not change the already-converged state.
        state.receiveExternalInactive(event: 1, token: Self.token(1))
        #expect(state.displayedOwner == .native(hoverEventID: 2))
        #expect(state.displayedURL == "https://example.com/new")
    }

    // 8. "retry bound": the existing bounded-retry contract this fix must
    // not weaken or replace ("2回falseなら3回目をscheduleしない" — a
    // second consecutive failure does NOT get a further attempt) is
    // Ghostty's own `externalHoverAckReducer`, already covered by its own
    // Zig test (`renderer/Thread.zig`: "a failed inactive ack stages
    // exactly one retry") and left untouched by this fix. What THIS
    // reducer must independently guarantee, since it has no visibility
    // into attempt counts at all, is that repeated deliveries of the same
    // inactive are idempotent no-ops past the first — never "eventually
    // delivered" framed as a guarantee, just safe to call more than once.
    @Test("Repeated identical inactive deliveries are idempotent, never re-triggering a promotion")
    func repeatedIdenticalInactiveDeliveriesAreIdempotent() {
        var state = TerminalHoverIndicatorState()
        state.receiveExternalActive(event: 1, token: Self.token(1), path: "/external/path")
        state.receiveNative(event: 2, url: "https://example.com/new")
        state.receiveExternalInactive(event: 1, token: Self.token(1))
        let convergedState = state

        // A second AND third identical delivery (standing in for however
        // many redeliveries a retry mechanism might produce) must be
        // exact no-ops — this is deliberately NOT a claim that delivery
        // is guaranteed, only that repeats never corrupt or re-promote.
        state.receiveExternalInactive(event: 1, token: Self.token(1))
        state.receiveExternalInactive(event: 1, token: Self.token(1))

        #expect(state == convergedState)
    }

    // 9. app projection: while the reducer holds a deferred native under
    // an active external owner, the fragment/candidate URL must never
    // reach `displayedURL` (the AppKit call sites project ONLY this
    // value to `setLinkHoverURL`) — and the promoted URL must appear
    // exactly once, precisely at the matching inactive, never before.
    @Test("displayedURL never surfaces a deferred native and updates exactly once on promotion")
    func displayedURLNeverSurfacesDeferredNativeAndUpdatesOnceOnPromotion() {
        var state = TerminalHoverIndicatorState()
        state.receiveExternalActive(event: 1, token: Self.token(1), path: "/external/path")
        #expect(state.displayedURL == "/external/path")

        state.receiveNative(event: 2, url: "https://example.com/fragment")
        // Unchanged — the fragment must not have surfaced.
        #expect(state.displayedURL == "/external/path")

        state.receiveNative(event: 3, url: "https://example.com/still-not-surfaced")
        #expect(state.displayedURL == "/external/path")

        state.receiveExternalInactive(event: 1, token: Self.token(1))
        // Promotes exactly once, to the LATEST deferred result (latest-wins).
        #expect(state.displayedURL == "https://example.com/still-not-surfaced")
    }
}
