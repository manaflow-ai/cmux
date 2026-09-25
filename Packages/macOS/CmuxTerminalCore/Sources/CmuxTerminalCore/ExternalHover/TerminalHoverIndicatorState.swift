import Foundation

/// (B) ExternalHover — the pure reducer deciding what the bottom-left
/// hover indicator shows, given native `MOUSE_OVER_LINK` results and
/// (B) ExternalHover activate/inactivate transitions arriving in
/// whatever order the real system actually delivers them in.
///
/// ## Why a token-lifetime reducer, not host-event-id comparison
///
/// A dogfood regression (see ``TerminalHoverIndicatorOwner``'s doc)
/// showed that comparing `hoverEventID`s to decide whether a native
/// result should displace an active external owner is unsound: the
/// host's `hoverEventID` bumps on every mouse-affecting AppKit event,
/// unconditionally, while Ghostty's own `hover_input_epoch` only bumps on
/// a cell/eligibility change. A native result answering a "newer" host
/// event id can still be revalidating the exact same Ghostty-side state
/// that minted the still-current external token — so it must never win
/// on event-id ordering alone. External ownership now lives and dies
/// strictly by Ghostty's own activation token: an explicit
/// `receiveExternalActive` installs it, an explicit
/// `receiveExternalInactive` for that SAME token retires it. Nothing else
/// (including any native result, of any event id) can evict an active
/// external owner.
///
/// ## Why a deferred native, not just discarding it
///
/// Simply refusing to let native displace external is not sufficient on
/// its own: Ghostty's real delivery order for a cell-to-cell move is
/// `external active(N, T) -> native result(N+1, new URL) -> inactive(T)`
/// (the native `mouse_over_link` action fires synchronously from
/// `Surface.cursorPosCallback`, while the external token's destructive
/// invalidation is only staged during the renderer's next `updateFrame`
/// and delivered as `inactive` on a LATER renderer turn — see
/// `Surface.zig`/`renderer/Thread.zig`). If the native result were simply
/// dropped, the indicator would go straight from the external path to
/// `.none` on `inactive`, and the native/OSC8 handoff that's supposed to
/// take over would show nothing until Ghostty happens to resend that
/// result again (not guaranteed). Holding the suppressed native result in
/// `deferredNative` and promoting it exactly at the matching `inactive`
/// closes that gap, while a genuinely stale/older native (one Ghostty
/// itself would never have raced against the current token — i.e. at or
/// before the external's own mint event) is still discarded outright,
/// never even reaching `deferredNative` (this is what actually reproduces
/// the old B0-3 guarantee: an external owner is never visibly displaced
/// by an older native, deferred or not).
///
/// ## On "bounded retry"
///
/// Ghostty's own action-delivery layer retries a failed `inactive` ack
/// exactly once (`externalHoverAckReducer` in `renderer/Thread.zig`) and
/// gives up after a second consecutive failure — this reducer has no
/// visibility into that at all: from here, "the retry succeeded" and
/// "it was delivered on the first try" are the exact same input, a single
/// `receiveExternalInactive` call. This reducer does not add, and must
/// not need, any retry/timer logic of its own; two consecutive failures
/// upstream are backstopped by surface teardown / host-initiated
/// withdrawal / current-request invalidation elsewhere in the system, not
/// by anything here.
///
/// ## Host-initiated withdrawal
///
/// A host-initiated clear (Cmd release, selection, remote, cwd/scroll/
/// resize, visibility loss — routed through the shared
/// `ExternalHoverOwnerCoordinator.withdrawUnconditionally()`/
/// `project(nil)` path) removes the CURRENT external owner exactly the
/// way a real Ghostty `inactive` does: the caller reads this state's own
/// `displayedOwner` for whichever `(event, token)` is currently
/// `.external` and feeds that straight back into
/// `receiveExternalInactive` — never a separate ad-hoc "just blank the
/// label" path. This is what lets a deferred native still get promoted
/// even when the withdrawal was host-initiated rather than a genuine
/// Ghostty ack.
public struct TerminalHoverIndicatorState: Sendable, Equatable {
    /// A native `MOUSE_OVER_LINK` result received while an external owner
    /// was active for a still-current token, held back from display.
    public struct NativeHoverResult: Sendable, Equatable {
        public let event: UInt64
        public let url: String?

        public init(event: UInt64, url: String?) {
            self.event = event
            self.url = url
        }
    }

    public private(set) var displayedOwner: TerminalHoverIndicatorOwner
    /// The link text currently visible for `displayedOwner`: the native
    /// URL for `.native`, the resolved path for `.external`, `nil` for
    /// `.none`. One field regardless of which owner produced it, since
    /// the AppKit projection needs exactly one "what to show" answer —
    /// `setLinkHoverURL(state.displayedURL)` is the entire projection
    /// contract; nothing else ever reads a fragment/deferred value.
    public private(set) var displayedURL: String?
    /// The latest native result suppressed while `displayedOwner` is
    /// `.external` for the token it was suppressed under. Cleared
    /// whenever a NEW external owner is installed (`receiveExternalActive`)
    /// — a native result deferred under a previous external's tenure must
    /// never become a later external's `inactive` fallback — and whenever
    /// it is promoted or discarded by `receiveExternalInactive`.
    public private(set) var deferredNative: NativeHoverResult?

    public init(
        displayedOwner: TerminalHoverIndicatorOwner = .none,
        displayedURL: String? = nil,
        deferredNative: NativeHoverResult? = nil
    ) {
        self.displayedOwner = displayedOwner
        self.displayedURL = displayedURL
        self.deferredNative = deferredNative
    }

    /// A native hover callback answering `event` arrived, with `url` set
    /// to the link text it found (`nil`/empty if it found nothing).
    public mutating func receiveNative(event: UInt64, url: String?) {
        switch displayedOwner {
        case .external(let ownedEvent, _):
            // B0-3: a native result for the SAME event external was
            // minted against, or an older one, is exactly the race the
            // old event-id-ordering rule got wrong — Ghostty never
            // actually invalidated the current token for this, so it is
            // discarded outright, never even held in `deferredNative`.
            guard event > ownedEvent else { return }
            // Latest-wins: never let an out-of-order older native
            // clobber a newer one already held.
            if let existing = deferredNative, existing.event > event {
                return
            }
            deferredNative = NativeHoverResult(event: event, url: url)
        case .none:
            guard let url, !url.isEmpty else { return }
            displayedOwner = .native(hoverEventID: event)
            displayedURL = url
        case .native(let ownedEvent):
            if let url, !url.isEmpty {
                guard ownedEvent <= event else { return }
                displayedOwner = .native(hoverEventID: event)
                displayedURL = url
            } else if ownedEvent == event {
                displayedOwner = .none
                displayedURL = nil
            }
        }
    }

    /// (B) ExternalHover activated for `event`/`token`, with the resolved
    /// `path` to display. Always replaces whatever was previously shown,
    /// and starts this token's tenure with a clean deferred slate.
    public mutating func receiveExternalActive(
        event: UInt64,
        token: HoverActivationTokenValue,
        path: String
    ) {
        displayedOwner = .external(hoverEventID: event, token: token)
        displayedURL = path
        deferredNative = nil
    }

    /// (B) ExternalHover deactivated for `event`/`token` — a real Ghostty
    /// ack, or a host-initiated withdrawal feeding back this state's own
    /// current `.external` owner (see the type's doc). A complete no-op
    /// unless `displayedOwner` is STILL exactly this `(event, token)` —
    /// a stale/duplicate call for an owner already replaced or already
    /// cleared changes nothing, including leaving any newer owner's own
    /// `deferredNative` untouched. On a real match, promotes
    /// `deferredNative` if one exists and carries a non-empty URL,
    /// otherwise clears to `.none`.
    public mutating func receiveExternalInactive(event: UInt64, token: HoverActivationTokenValue) {
        guard case .external(let ownedEvent, let ownedToken) = displayedOwner,
              ownedEvent == event, ownedToken == token else {
            return
        }
        if let deferred = deferredNative, let url = deferred.url, !url.isEmpty {
            displayedOwner = .native(hoverEventID: deferred.event)
            displayedURL = url
        } else {
            displayedOwner = .none
            displayedURL = nil
        }
        deferredNative = nil
    }
}
