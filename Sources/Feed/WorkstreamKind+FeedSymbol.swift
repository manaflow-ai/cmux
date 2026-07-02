import CMUXAgentLaunch

extension WorkstreamKind {
    var symbolName: String {
        switch self {
        case .permissionRequest: return "lock.shield"
        case .approvalWait: return "bell.badge"
        case .exitPlan: return "list.bullet.rectangle"
        case .question: return "questionmark.circle"
        case .toolUse, .toolResult: return "terminal"
        case .userPrompt: return "person"
        case .assistantMessage: return "sparkles"
        case .sessionStart, .sessionEnd: return "play.circle"
        case .stop: return "stop.circle"
        case .todos: return "checklist"
        }
    }
}
