public import CmuxNextDesignTokens
public import Foundation

/// Hover card timing for the sidebar's workspace cards, the tab cards and every other native hover
/// card. The numbers are Chrome's and live in one place, `HoverIntentTiming.cardDelay` and
/// `.cardReshow` (HoverIntent.swift, with the Chromium files and constants they come from).
/// History: 1300 ms (2026-10-14), 250 ms (2026-10-18, msg 1754), Chrome's 1300 ms (2026-10-28,
/// msg 15729), 400 ms with a rest shortcut (Leo 2026-11-01), and Chrome's exactly again with no
/// shortcut (Lawrence 2026-11-15, msg 32286: "need more delay (copy chrome's delay exactly ...)
/// and make sure it is consistent between every thing").
public nonisolated struct HoverCardTiming {
    public nonisolated init() {}
    /// The cold delay: how long the pointer rests on a row, a tab or any other target before the
    /// first card opens. Every target waits the same. `sidebar.hoverCards.delay` overrides it
    /// (`DesignSettings.hoverCardDelay`).
    public static let showDelay: Duration = HoverIntentTiming.cardDelay
    /// Warm mode: after a card goes, a hover this soon shows the next one at once (Chrome's
    /// `kShowWithoutDelayTimeBuffer`); a gap between rows this short keeps the card. While a card
    /// shows, the next target's card replaces it at once and the card slides over (`HoverCardPanel`).
    public static let reshowWindow: Duration = HoverIntentTiming.cardReshow
    /// A sweep: a retarget this soon after the last show or retarget puts the card at its row
    /// with its new content in that frame, with no slide, crossfade or resize (`HoverCardPanel`).
    /// A pointer crossing rows faster than the card's slide settles (the `.panel` spring, about
    /// 0.2 s) restarted it on every row, so the card trailed the pointer and its text doubled
    /// mid-crossfade (Lawrence 2026-10-28, msg 15501: "card animation needs to be better, if i
    /// move across it very fast"). A deliberate move to the next row comes later and glides.
    public static let sweepInterval: Duration = .milliseconds(150) // hover-timing: animation choice, not a show or hide delay
}

extension DesignSettings {
    /// Posted when `hoverCardsEnabled` changes (the hover card coordinator hides a shown card).
    public static let hoverCardsDidChange = Notification.Name("CmuxNextDesign.DesignSettings.hoverCardsDidChange")
}
