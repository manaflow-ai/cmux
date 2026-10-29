#if os(iOS)
import SwiftUI

extension NavigationPath {
    /// Home's stack for a tapped Chief notification about `conversationID`:
    /// the Cloud Chief's conversation, another conversation of the focused
    /// Mac's Home list, or else the Mac Chief (as before conversations were
    /// told apart). A notification for a conversation that is gone opens the
    /// Mac Chief rather than nothing.
    @MainActor
    public init(chiefConversation conversationID: String?, sources: ChiefSources = .shared, feed: MacHomeFeed = .shared) {
        self.init()
        guard let conversationID, conversationID != sources.mac.conversationID else {
            append(ChiefRoute(place: .mac))
            return
        }
        if conversationID == sources.cloud.conversationID {
            append(ChiefRoute(place: .cloud))
        } else if let row = feed.rows?.first(where: { $0.id == conversationID }), row.id != feed.macChiefID {
            append(MacConversationRoute(conversationID: row.id, chief: row.chief, title: row.title))
        } else {
            append(ChiefRoute(place: .mac))
        }
    }
}
#endif
