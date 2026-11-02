import CCmuxMotionFFI
public import Foundation
public import CmuxNextDesignTokens

/// Hover card timing for the sidebar's workspace cards and the tab cards, from cmux-motion
/// (cmux-tui/crates/cmux-motion/src/hover/timing.rs: Chrome's tab hover card timing, then Leo's
/// 400 ms cold delay of 2026-11-01; the history of each value is there).
public nonisolated struct HoverCardTiming {
    public nonisolated init() {}
    /// The cold delay: how long the pointer rests on a row or a tab before the first card opens.
    /// Rows and tabs wait the same (no width scaling). `sidebar.hoverCards.delay` overrides it
    /// (`DesignSettings.hoverCardDelay`).
    public static let showDelay = Duration(hoverNanoseconds: HoverIntentTiming.rustTable.card_show_delay)
    /// Warm mode: after a card goes, a hover this soon shows the next one at once (Chrome's
    /// `kShowWithoutDelayTimeBuffer`); a gap between rows this short keeps the card. While a card
    /// shows, the next target's card replaces it at once and the card slides over (`HoverCardPanel`).
    public static let reshowWindow = Duration(hoverNanoseconds: HoverIntentTiming.rustTable.card_reshow_window)
    /// A sweep: a retarget this soon after the last show or retarget puts the card at its row
    /// with its new content in that frame, with no slide, crossfade or resize (`HoverCardPanel`).
    public static let sweepInterval = Duration(hoverNanoseconds: HoverIntentTiming.rustTable.card_sweep_interval)
    /// How long a pinned card (Show Resource Usage) stays without a dismissal.
    public static let pinLifetime = Duration(hoverNanoseconds: HoverIntentTiming.rustTable.card_pin_lifetime)
    /// How long a target with no delay waits when it arrives under a still pointer.
    public static let stillPointerDelay = Duration(hoverNanoseconds: HoverIntentTiming.rustTable.card_still_pointer_delay)
}

extension DesignSettings {
    /// Posted when `hoverCardsEnabled` changes (the hover card coordinator hides a shown card).
    public static let hoverCardsDidChange = Notification.Name("CmuxNextDesign.DesignSettings.hoverCardsDidChange")
}
