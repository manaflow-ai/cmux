import CmuxNextDaemonService
public import CmuxNextSidebar
import Foundation

/// The sidebar's "Create a Cloud machine?" card for a create no person started, shown only while the person
/// turned asking on: Create, Cancel and a Don't Ask Again switch (Leo, 2026-11-04: "a cute toggle or checkmark").
public struct CloudCreateRequestAsk {
    public init() {}
    static let create = "yes", stopAsking = "stopAsking"

    /// True for Create or the switch; the switch also runs `stopAsking`, and no `stopAsking` (a managed preference) shows no switch.
    @MainActor public static func ask(_ asks: SidebarAsks, intro: String, lines: [String], asker: String?,
                                      present: @escaping @MainActor @Sendable (String) -> Bool, stopAsking: (@MainActor () async -> Void)?) async -> Bool {
        let actions = [SidebarNoticeCard.Action(id: create, title: CloudStrings.createConfirmButton, prominent: true), SidebarNoticeCard.Action(id: "no", title: CloudStrings.cancel)]
            + (stopAsking == nil ? [] : [SidebarNoticeCard.Action(id: Self.stopAsking, title: CloudStrings.createStopAsking, isSwitch: true)])
        let card = SidebarNoticeCard(id: "ask.\(UUID().uuidString)", symbol: "cloud", title: CloudStrings.createConfirmTitle, detail: intro, lines: lines,
                                     actions: actions, dismissLabel: CloudStrings.cancel)
        switch await asks.choose(card, asker: asker, present: present) {
        case create?: return true
        case Self.stopAsking?: await stopAsking?(); return true
        default: return false
        }
    }
}
