import Foundation

/// A collapsible sidebar section that groups sessions by their agent status.
struct SessionCardGroup: Equatable, Identifiable {
    static let pinnedID = "pinned"
    static let otherID = "other"

    let id: String
    let title: String
    let statuses: Set<SessionCardSnapshot.Status>

    static let pinned = SessionCardGroup(
        id: pinnedID,
        title: String(localized: "sidebar.sessionGroup.pinned", defaultValue: "Pinned"),
        statuses: []
    )

    static let defaultStatusGroups = [
        SessionCardGroup(
            id: "needsAttention",
            title: String(localized: "sidebar.sessionGroup.needsAttention", defaultValue: "Needs Attention"),
            statuses: [.needsInput]
        ),
        SessionCardGroup(
            id: "running",
            title: String(localized: "sidebar.sessionGroup.running", defaultValue: "Running"),
            statuses: [.working, .babysitting]
        ),
        SessionCardGroup(
            id: "finished",
            title: String(localized: "sidebar.sessionGroup.finished", defaultValue: "Finished"),
            statuses: [.ready, .done, .exited]
        ),
    ]

    static let other = SessionCardGroup(
        id: otherID,
        title: String(localized: "sidebar.sessionGroup.other", defaultValue: "Other"),
        statuses: []
    )

    static func groups(configured: [SessionCardGroup]) -> [SessionCardGroup] {
        [.pinned] + (configured.isEmpty ? defaultStatusGroups : configured) + [.other]
    }

    static func resolveID(
        status: SessionCardSnapshot.Status,
        isPinned: Bool,
        configured: [SessionCardGroup]
    ) -> String {
        if isPinned {
            return pinnedID
        }
        let statusGroups = configured.isEmpty ? defaultStatusGroups : configured
        return statusGroups.first(where: { $0.statuses.contains(status) })?.id ?? otherID
    }
}
