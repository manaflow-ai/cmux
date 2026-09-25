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

    // impl-flicker-fix (review-flicker-fix-confirm.md §5, cmux integration
    // items 12-15) — confirms this EXISTING reducer, unmodified by the
    // flicker fix itself, correctly handles the event sequence Ghostty's
    // now-fixed core actually produces: no more spurious `inactive`
    // while the pointer stays within a resolved link's ranges, and a
    // real `inactive` exactly once when it truly leaves them.

    // 12+13. Several same-range cell moves (Ghostty core no longer emits
    // any `inactive` for these — see `Mouse.updateExternalHoverPointerCell`'s
    // Zig-side tests) must never transition the indicator away from the
    // external path; a REAL range-exit inactive (immediately after) must
    // then promote whatever native result was deferred during that
    // sequence, exactly once.
    @Test("Same-range cell moves never transition away from external; a real range exit promotes deferred native")
    func sameRangeMovesStayExternalThenRealExitPromotesDeferredNative() {
        var state = TerminalHoverIndicatorState()
        state.receiveExternalActive(event: 1, token: Self.token(1), path: "/full/two/line/path.md")

        // Several same-range cell moves — Ghostty core produces NO
        // `inactive` for any of these post-fix, so the reducer only ever
        // sees native results (occasionally resent by Ghostty for
        // adjacent cells) arriving while external stays active.
        for event in UInt64(2)...5 {
            state.receiveNative(event: event, url: "https://example.com/fragment-\(event)")
            #expect(state.displayedOwner == .external(hoverEventID: 1, token: Self.token(1)))
            #expect(state.displayedURL == "/full/two/line/path.md")
        }

        // The pointer genuinely leaves the range — Ghostty core's
        // input-time invalidation produces exactly one real `inactive`.
        state.receiveExternalInactive(event: 1, token: Self.token(1))

        // Promotes to the LATEST deferred native from the sequence above.
        #expect(state.displayedOwner == .native(hoverEventID: 5))
        #expect(state.displayedURL == "https://example.com/fragment-5")
    }

    // 14. Moving back to the original range at native (post-fix) speed —
    // i.e. before any fresh setter call has resolved a new candidate —
    // must not revive the old external owner. Only a genuinely fresh
    // `receiveExternalActive` (standing in for a fresh setter/ack) can
    // reactivate it.
    @Test("Returning to the original range does not revive the old owner without a fresh activation")
    func returningToOriginalRangeDoesNotReviveWithoutFreshActivation() {
        var state = TerminalHoverIndicatorState()
        state.receiveExternalActive(event: 1, token: Self.token(1), path: "/external/path")
        state.receiveExternalInactive(event: 1, token: Self.token(1))
        #expect(state.displayedOwner == .none)

        // A stale/duplicate redelivery of the same inactive (e.g. a
        // retried ack) while nothing has re-activated is a no-op, not a
        // revival.
        state.receiveExternalInactive(event: 1, token: Self.token(1))
        #expect(state.displayedOwner == .none)

        // Only a genuinely fresh activation (a new event AND a new
        // token, standing in for a real new setter call after the
        // pointer re-entered the range and Ghostty re-resolved it)
        // reactivates — never the OLD token.
        state.receiveExternalActive(event: 2, token: Self.token(2), path: "/external/path")
        #expect(state.displayedOwner == .external(hoverEventID: 2, token: Self.token(2)))
    }

    // 15. Scroll: the host's own scroll-triggered withdrawal
    // (`GhosttyNSView`'s `GHOSTTY_ACTION_SCROLLBAR` handler, routed
    // through this same `receiveExternalInactive` entry point per
    // `TerminalHoverIndicatorState`'s "Host-initiated withdrawal" doc)
    // can race Ghostty core's own viewport-identity invalidation (the
    // physical-token mismatch from `row_space_revision`/offset changing
    // — see `renderer/link.zig`'s viewport-identity tests) for the exact
    // SAME scroll. Both ultimately funnel through `receiveExternalInactive`
    // for the SAME `(event, token)`; regardless of delivery order or
    // duplication, the reducer must converge to `.none` exactly once,
    // idempotently.
    @Test("Racing scroll-triggered withdrawal and core viewport invalidation converge idempotently")
    func racingScrollWithdrawalAndCoreInvalidationConvergeIdempotently() {
        var hostTriggered = TerminalHoverIndicatorState()
        hostTriggered.receiveExternalActive(event: 1, token: Self.token(1), path: "/external/path")
        // Host's scroll handler fires first.
        hostTriggered.receiveExternalInactive(event: 1, token: Self.token(1))
        // Core's own viewport-invalidation-driven inactive ack for the
        // SAME token arrives after — a no-op, not a second transition.
        hostTriggered.receiveExternalInactive(event: 1, token: Self.token(1))
        #expect(hostTriggered.displayedOwner == .none)

        var coreTriggered = TerminalHoverIndicatorState()
        coreTriggered.receiveExternalActive(event: 1, token: Self.token(1), path: "/external/path")
        // Reversed order: core's invalidation-driven inactive arrives
        // first, the host's own scroll withdrawal for the same token
        // arrives after.
        coreTriggered.receiveExternalInactive(event: 1, token: Self.token(1))
        coreTriggered.receiveExternalInactive(event: 1, token: Self.token(1))
        #expect(coreTriggered.displayedOwner == .none)

        // Both orderings converge to the exact same final state.
        #expect(hostTriggered == coreTriggered)
    }
}
