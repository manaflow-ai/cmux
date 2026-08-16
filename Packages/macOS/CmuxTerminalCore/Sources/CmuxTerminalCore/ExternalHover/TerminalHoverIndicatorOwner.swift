import Foundation

/// (B) ExternalHover — which mechanism (native Ghostty regex hover, or an
/// (B) ExternalHover override) currently owns the visible hover indicator.
///
/// Carries no transition rules of its own — it is a pure identity value.
/// The actual accept/defer/promote rules governing when this changes live
/// on ``TerminalHoverIndicatorState``, which owns one of these plus the
/// bookkeeping (a possibly-deferred native result) those rules need. An
/// earlier revision of this type carried its own `receivingNativeResult`/
/// `receivingExternalActive`/`receivingExternalInactive` methods that
/// decided displacement purely from `hoverEventID` ordering — including a
/// rule that let a newer-event native result replace an active external
/// owner outright. That rule caused a real dogfood regression: Ghostty's
/// `hover_input_epoch` only bumps on a cell/eligibility change, while the
/// host's `hoverEventID` bumps unconditionally on every event, so a single
/// sub-pixel mouse move within the SAME cell could bump `hoverEventID`
/// without Ghostty ever re-validating anything — the next (re-sent, same
/// cell) native result then looked "newer" by event id alone and evicted
/// a still-valid external owner that Ghostty had no reason to invalidate.
/// See ``TerminalHoverIndicatorState`` for the fix: external ownership
/// now lives and dies by Ghostty's own activation token (explicit
/// activate/inactivate), never by host event-id comparison.
public enum TerminalHoverIndicatorOwner: Sendable, Equatable {
    case none
    case native(hoverEventID: UInt64)
    case external(hoverEventID: UInt64, token: HoverActivationTokenValue)

    /// (C) ExternalHover diagnostics — design v4 §5's `projection` stage
    /// `ownerBefore`/`ownerAfter` fields: a kind label only, never the
    /// associated `hoverEventID`/`token` (design v4 §5's secrecy policy —
    /// no raw token/path values in any diagnostic line).
    public var diagnosticKind: String {
        switch self {
        case .none: return "none"
        case .native: return "native"
        case .external: return "external"
        }
    }
}
