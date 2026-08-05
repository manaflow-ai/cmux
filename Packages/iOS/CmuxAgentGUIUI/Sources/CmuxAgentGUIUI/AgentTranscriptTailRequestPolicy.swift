#if os(iOS)
import CmuxAgentChatUI

enum AgentTranscriptTailRequestAction: Equatable {
    case localScroll
    case semanticTail
}

struct AgentTranscriptTailRequestPolicy {
    static func action(hasMoreAfter: Bool) -> AgentTranscriptTailRequestAction {
        hasMoreAfter ? .semanticTail : .localScroll
    }

    static func followStateBeforeCommand<ID: Hashable>(
        current: ConversationFollowState<ID>,
        action: AgentTranscriptTailRequestAction
    ) -> ConversationFollowState<ID> {
        switch action {
        case .localScroll:
            current
        case .semanticTail:
            .jumpingToTail
        }
    }
}
#endif
