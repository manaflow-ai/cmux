import Foundation

/// (B) ExternalHover — which mechanism (native Ghostty regex hover, or an
/// (B) ExternalHover override) is currently driving the visible hover
/// indicator, and cross-thread ordering between the two.
///
/// The host increments a per-surface `hoverEventID` serial BEFORE forwarding
/// a hover-affecting event (mouse move, Cmd press/release, etc.) to Ghostty.
/// Ghostty's native `MOUSE_OVER_LINK` callback must copy that serial (and
/// surface identity) into its closure synchronously, at dispatch time — not
/// "read the current ID on arrival" — so `receivingNativeResult` always
/// describes the event the callback was actually answering, even if a newer
/// event has since been dispatched and is still in flight.
public enum TerminalHoverIndicatorOwner: Sendable, Equatable {
    case none
    case native(hoverEventID: UInt64)
    case external(hoverEventID: UInt64, token: HoverActivationTokenValue)

    /// A native hover callback answering `hoverEventID` arrived, with
    /// `url` set to the link text it found (`nil`/empty if it found
    /// nothing).
    ///
    /// An (B) ExternalHover owner already installed for the SAME event
    /// takes priority — external, once active for an event, is never
    /// displaced by that same event's native result arriving later (native
    /// and external race to answer the same event; external winning is a
    /// deliberate, not accidental, outcome once it happens). A native
    /// result for an OLDER event is stale and must not clear or replace
    /// whatever is currently showing for a newer event.
    public func receivingNativeResult(hoverEventID: UInt64, url: String?) -> TerminalHoverIndicatorOwner {
        if case .external(let ownedEvent, _) = self, ownedEvent == hoverEventID {
            return self
        }
        guard let url, !url.isEmpty else {
            if case .native(let ownedEvent) = self, ownedEvent == hoverEventID {
                return .none
            }
            return self
        }
        switch self {
        case .none:
            return .native(hoverEventID: hoverEventID)
        case .native(let ownedEvent):
            return ownedEvent <= hoverEventID ? .native(hoverEventID: hoverEventID) : self
        case .external(let ownedEvent, _):
            // Not the same event (checked above) and external only ever
            // wins for the event it was minted against, so a native result
            // for a different (necessarily newer, since external can't
            // predate its own mint) event takes over here.
            return ownedEvent < hoverEventID ? .native(hoverEventID: hoverEventID) : self
        }
    }

    /// (B) ExternalHover activated (`active == true`) for `hoverEventID` /
    /// `token`. Always replaces whatever is currently displayed — matches
    /// the Ghostty render loop's own OSC8/regex-suppression priority: once
    /// external is active for an event, it wins outright.
    public func receivingExternalActive(
        hoverEventID: UInt64,
        token: HoverActivationTokenValue
    ) -> TerminalHoverIndicatorOwner {
        .external(hoverEventID: hoverEventID, token: token)
    }

    /// (B) ExternalHover deactivated for `hoverEventID`/`token`. Only clears
    /// if this value is STILL `.external` with that same event and token —
    /// a newer owner already installed (different event or different
    /// token), or a value that was never this owner, is left untouched.
    public func receivingExternalInactive(
        hoverEventID: UInt64,
        token: HoverActivationTokenValue
    ) -> TerminalHoverIndicatorOwner {
        if case .external(let ownedEvent, let ownedToken) = self,
           ownedEvent == hoverEventID, ownedToken == token {
            return .none
        }
        return self
    }
}
