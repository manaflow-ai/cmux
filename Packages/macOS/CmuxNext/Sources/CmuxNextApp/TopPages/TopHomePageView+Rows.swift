import CmuxHomeCore
import CmuxNextHomeEngine

/// Which conversations classic Home lists and opens on.
extension TopHomePageView {
    /// The rows the list shows: an archived Chief's conversation is hidden
    /// (its history stays with the owner, read-only).
    static func visible(_ rows: [InboxRow], archivedChiefs: Set<String>, me: ParticipantID?) -> [InboxRow] {
        guard !archivedChiefs.isEmpty else { return rows }
        return rows.filter { row in
            guard row.kind == .chief else { return true }
            return !row.summary.participants.contains { $0.id != me && archivedChiefs.contains($0.id.rawValue) }
        }
    }

    /// The Chief conversation Home opens on: the chief placed on a server takes over a local one
    /// without history (`HomeChiefSource`).
    static func chief(_ home: HomeService) -> String? {
        let local = HomeChiefName.select(from: home.conversations)
        return home.tabChiefs.chiefTab(local: local?.id, localHasHistory: (local?.lastSeq ?? 0) > 0, choice: home.hostedChief.choice)
    }
}
