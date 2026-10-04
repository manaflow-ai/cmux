import CmuxNextDaemon
import Foundation

extension HomeService {
    /// The local mux participant every local conversation starts with.
    static let mux = ConversationParticipant(id: "agent_mux", kind: .agent, displayName: "Chief", agentClass: "mux", acpSession: "mux")

    /// The local user as a participant, named after the macOS account.
    static var localUser: ConversationParticipant {
        let name = NSFullUserName().isEmpty ? NSUserName() : NSFullUserName()
        return ConversationParticipant(id: ConversationParticipant.localUserID, kind: .human, displayName: name)
    }

    /// A new local conversation with the mux (user origin; the owner assigns the id).
    func createConversation(title: String = HomeStrings.newConversationTitle) {
        guard let connection else { return }
        let request = CreateConversationRequest(idempotencyKey: "create:" + UUID().uuidString.lowercased(), title: title,
                                                participants: [Self.localUser, Self.mux])
        // task-owner: one conversation-create write; ends with its reply
        Task { [weak self] in
            do {
                _ = try await ConversationClient(connection).create(request)
                self?.reloadList(connection)
            } catch {
                self?.logger.error("conversation-create: \(String(describing: error), privacy: .public)")
            }
        }
    }
}
