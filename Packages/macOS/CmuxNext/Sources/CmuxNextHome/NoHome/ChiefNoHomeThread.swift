#if DEBUG
import SwiftUI

/// DEBUG ONLY: one thread in the no-Home prototype: the Chief, another Chief, a group chat, a DM, a Chief subagent
/// or an agent chat in a workspace. Every kind draws as the same row (``ChiefNoHomeThreadRow``).
struct ChiefNoHomeThread: Identifiable, Hashable {
    enum Kind: Hashable { case chief, otherChief, group, direct, subagent, agent }
    enum Status: Hashable { case idle, working, needsYou, done }

    var id: String
    var kind: Kind
    var title: String
    var detail: String
    var status: Status = .idle
    var unread = 0
    /// The workspace the thread works in (agent chats and subagents), by ``ChiefNoHomeWorkspace/id``.
    var workspace: String?
    var minutesAgo = 0

    /// The thread's avatar symbol: the Chief's sparkles, a person, a group, an agent.
    var symbol: String {
        switch kind {
        case .chief, .otherChief: "sparkles"
        case .group: "person.3.fill"
        case .direct: "person.crop.circle.fill"
        case .subagent: "arrow.turn.down.right"
        case .agent: "terminal"
        }
    }

    /// The avatar's tint: the Chief in the accent color, the rest in their own hue.
    var tint: Color {
        switch kind {
        case .chief: Color(nsColor: .controlAccentColor)
        case .otherChief: .purple
        case .group: .teal
        case .direct: .orange
        case .subagent, .agent: .secondary
        }
    }
}
#endif
