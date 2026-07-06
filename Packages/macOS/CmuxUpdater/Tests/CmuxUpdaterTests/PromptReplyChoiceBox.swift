@preconcurrency import Sparkle

@MainActor
final class PromptReplyChoiceBox {
    private(set) var choices: [SPUUserUpdateChoice] = []

    func append(_ choice: SPUUserUpdateChoice) {
        choices.append(choice)
    }
}
