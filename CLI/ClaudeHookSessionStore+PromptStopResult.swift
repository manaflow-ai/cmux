extension ClaudeHookSessionStore {
    enum PromptStopResult: Equatable {
        case applied(nested: Bool)
        case alreadySettled
        case rejectedByLifecycleFence

        var nested: Bool {
            guard case .applied(let nested) = self else { return false }
            return nested
        }

        var wasAlreadySettled: Bool {
            if case .alreadySettled = self { return true }
            return false
        }

        var wasRejectedByLifecycleFence: Bool {
            if case .rejectedByLifecycleFence = self { return true }
            return false
        }
    }
}
