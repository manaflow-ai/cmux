import Foundation

extension SidebarNoticeCard {
    /// The one-time GitHub star ask (Lawrence 2026-11-15): the tip card's slot and look, a star above one short
    /// title, one quiet line, one button and a plain x with no menu (the x ends it). The card sends `shownAction`
    /// once it is on screen. Text arrives localized.
    public static func starPrompt(id: String, title: String, detail: String, open: Action, dismissLabel: String,
                                  shownAction: String) -> SidebarNoticeCard {
        SidebarNoticeCard(id: id, symbol: "star", title: title, detail: detail, actions: [open], dismissLabel: dismissLabel,
                          shownAction: shownAction)
    }
}
