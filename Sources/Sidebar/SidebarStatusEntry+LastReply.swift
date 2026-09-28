import CmuxSidebar
import Foundation

extension SidebarStatusEntry {
    /// The text every workspace row renderer shows for this entry: the
    /// status, then when the agent last replied (`Running · replied 7:41 AM`)
    /// once it has. The reply time stays visible while the turn runs or
    /// waits on background agents, when the agent's own "done" line has not
    /// appeared yet.
    var sidebarRowText: String {
        guard let lastReplyAt else { return sidebarDisplayText }
        return "\(sidebarDisplayText) · \(Self.lastReplyLabel(lastReplyAt, now: Date()))"
    }

    /// `replied 7:41 AM` today, `replied Sep 27, 7:41 PM` on another day,
    /// in the user's locale.
    static func lastReplyLabel(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let time = calendar.isDate(date, inSameDayAs: now)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        return String(
            localized: "sidebar.agentStatus.lastReply",
            defaultValue: "replied \(time)"
        )
    }
}
