public import CmuxNextActions
import CmuxNextAgentPane
public import CmuxNextPalette

extension AgentPriorityChats {
    /// The app's Priority chats: this Mac's acpmux and the Chief home's, archived over their sockets.
    @MainActor public static let app = makeApp()

    // A function, not the property's initial value: the archive closure is nonisolated, the stores main-actor.
    private static func makeApp() -> AgentPriorityChats {
        AgentPriorityChats(marks: .shared, stores: [.shared, .chief],
                           archive: { try await AcpmuxChatArchive(socketPath: $0).archive(sessionId: $1) },
                           unarchive: { try await AcpmuxChatArchive(socketPath: $0).unarchive(sessionId: $1) })
    }
}

/// The palette's list of Priority chats for a row action's `chat` argument, in rank order. Other
/// kinds fall through to `next`.
public final class PriorityChatTargetSource: PaletteTargetSource {
    private let chats: AgentPriorityChats
    private let next: any PaletteTargetSource

    public init(chats: AgentPriorityChats, next: any PaletteTargetSource) {
        self.chats = chats
        self.next = next
    }

    public func targets(of kind: ActionTargetKind) -> [PaletteTargetOption] {
        guard kind == .agentChat else { return next.targets(of: kind) }
        return chats.entries().map { entry in
            let place = [entry.project, entry.machine].compactMap(\.self).joined(separator: " · ")
            return PaletteTargetOption(id: entry.id, title: entry.title, subtitle: place.isEmpty ? nil : place, symbol: "bubble.left")
        }
    }

    public func title(of target: ActionTargetRef) -> String? {
        guard target.kind == .agentChat else { return next.title(of: target) }
        return chats.entry(target.id)?.title
    }

    public func currentDescription(of target: ActionTargetRef) -> String? {
        next.currentDescription(of: target)
    }
}
