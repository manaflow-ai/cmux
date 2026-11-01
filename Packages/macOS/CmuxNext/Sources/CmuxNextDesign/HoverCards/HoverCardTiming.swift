public import Foundation

/// Hover card timing for the sidebar's workspace cards and the tab cards.
///
/// Chrome's timing (Chromium chrome/browser/ui/views/tabs/hovercard/tab_hover_card_controller.cc,
/// read 2026-10-28 at 9220cdeed22f): `GetShowDelay` waits `kMaximumTriggerDelay` 800 ms plus
/// `kTabHoverCardAdditionalMaxWidthDelay` 500 ms for a tab at standard width and for a vertical
/// tab strip at its default width (narrower tabs scale down to 300 ms); `ShouldShowImmediately`
/// skips the wait within `kShowWithoutDelayTimeBuffer` 300 ms after the card went; an open card
/// moves to the next tab at once. History: 1300 ms (2026-10-14), then 250 ms when Lawrence found
/// it slow (2026-10-18, msg 1754), then back to Chrome's (2026-10-28, msg 15729: "we need to wait
/// a lot longer before opening the hover cards (see how long chrome takes and match them
/// properly)"), then 400 ms (Leo 2026-11-01: "i need these hover previews to appear a hell of a
/// lot faster than they do now"): Chrome's floor for a narrow tab plus a beat, so a pointer
/// passing over the sidebar still opens nothing, and the warm rules below keep later cards
/// instant.
public nonisolated struct HoverCardTiming {
    public nonisolated init() {}
    /// The cold delay: how long the pointer rests on a row or a tab before the first card opens.
    /// Rows and tabs wait the same (no width scaling). `sidebar.hoverCards.delay` overrides it
    /// (`DesignSettings.hoverCardDelay`).
    public static let showDelay: Duration = .milliseconds(400)
    /// Warm mode: after a card goes, a hover this soon shows the next one at once (Chrome's
    /// `kShowWithoutDelayTimeBuffer`); a gap between rows this short keeps the card. While a card shows, the next target's card replaces it at once and the card
    /// slides over (`HoverCardPanel`).
    public static let reshowWindow: Duration = .milliseconds(300)
    /// A sweep: a retarget this soon after the last show or retarget puts the card at its row
    /// with its new content in that frame, with no slide, crossfade or resize (`HoverCardPanel`).
    /// A pointer crossing rows faster than the card's slide settles (the `.panel` spring, about
    /// 0.2 s) restarted it on every row, so the card trailed the pointer and its text doubled
    /// mid-crossfade (Lawrence 2026-10-28, msg 15501: "card animation needs to be better, if i
    /// move across it very fast"). A deliberate move to the next row comes later and glides.
    public static let sweepInterval: Duration = .milliseconds(150)
}

extension DesignSettings {
    /// Posted when `hoverCardsEnabled` changes (the hover card coordinator hides a shown card).
    public static let hoverCardsDidChange = Notification.Name("CmuxNextDesign.DesignSettings.hoverCardsDidChange")
}
