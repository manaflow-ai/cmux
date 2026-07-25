#if os(iOS)
enum AgentTranscriptTailRequestAction: Equatable {
    case localScroll
    case semanticTail
}

struct AgentTranscriptTailRequestPolicy {
    static func action(hasMoreAfter: Bool) -> AgentTranscriptTailRequestAction {
        hasMoreAfter ? .semanticTail : .localScroll
    }
}
#endif
