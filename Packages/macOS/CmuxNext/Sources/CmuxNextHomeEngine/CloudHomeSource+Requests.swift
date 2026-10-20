import CmuxHomeCore
import CmuxNextDaemon
import CmuxNextHome
import Foundation

nonisolated extension CloudHomeSource: HomeMessageRequestSource {
    // MARK: Message requests (home-messaging-invites DESIGN 2.3)

    public func messageRequests() async throws -> [HomeMessageRequest] {
        guard let (commands, _, _) = try? requireEndpoint() else { return [] }
        return try await commands.messageRequests().compactMap(Self.request)
    }

    public func answer(_ conversation: ConversationID, _ answer: HomeRequestAnswer) async throws {
        let (commands, _, generation) = try requireEndpoint()
        let op: CloudConversationOp = switch answer {
        case .accept: .acceptRequest
        case .decline: .dismissRequest(block: false)
        case .block: .dismissRequest(block: true)
        }
        _ = try await commands.op(CloudConversationOpRequest(conversation: conversation.rawValue, idempotencyKey: UUID().uuidString, op: op))
        // An accepted request is now one of the user's conversations: list it.
        if answer == .accept { await reloadInbox(generation: generation) }
    }

    /// A listed request as Home shows it; a row without an inviter name or a conversation id is dropped.
    static func request(_ cloud: CloudMessageRequest) -> HomeMessageRequest? {
        guard !cloud.conversation.isEmpty, !cloud.inviter.isEmpty, !cloud.inviter.isHomeInternalID else { return nil }
        return HomeMessageRequest(conversation: ConversationID(cloud.conversation), inviter: cloud.inviter, isGroup: cloud.isGroup,
                                  title: cloud.title.flatMap { $0.isHomeInternalID ? nil : $0 }, preview: cloud.preview,
                                  createdAt: cloud.createdAt, trusted: cloud.trusted)
    }
}
