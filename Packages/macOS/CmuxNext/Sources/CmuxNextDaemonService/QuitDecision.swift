/// A quit decision: quit now with a choice, or ask (`QuitRules.decide`).
public enum QuitDecision: Equatable, Sendable {
    case quit(QuitSessionsChoice)
    case ask(QuitPrompt)
}
