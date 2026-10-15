public import Foundation

/// Chrome's tab hover card timing, which the sidebar's workspace cards and the tab cards follow
/// (Lawrence 2026-10-14: "dont show the card on hover for workspaces/tabs until XYZ seconds (see
/// how long google chrome takes for this)"). Source: Chromium
/// chrome/browser/ui/views/tabs/hovercard/tab_hover_card_controller.cc.
public nonisolated struct HoverCardTiming {
    public nonisolated init() {}
    /// The cold delay: what Chrome waits over a tab at its default (standard) width.
    /// `GetShowDelay`: at `tab_standard_width` the log fraction is 1, so the delay is
    /// `kMaximumTriggerDelay` (800 ms), and `tab_width >= tab_standard_width` adds
    /// `kTabHoverCardAdditionalMaxWidthDelay` (500 ms). Sidebar rows are always full width, so
    /// cmux applies no width scaling: rows and tabs wait the same. `sidebar.hoverCards.delay`
    /// overrides it (`DesignSettings.hoverCardDelay`).
    public static let chromeDelay: Duration = .milliseconds(1_300)
    /// `kShowWithoutDelayTimeBuffer`: after a card goes, a hover this soon shows the next one
    /// at once. While a card shows, the next target's card replaces it at once (Chrome's
    /// `UpdateOrShowCard` slides the visible card over).
    public static let reshowWindow: Duration = .milliseconds(300)
}

extension DesignSettings {
    /// Posted when `hoverCardsEnabled` changes (the hover card coordinator hides a shown card).
    public static let hoverCardsDidChange = Notification.Name("CmuxNextDesign.DesignSettings.hoverCardsDidChange")
}
