@testable import CmuxUpdater

@MainActor
final class PromptReplyChoiceBox {
    private(set) var choices: [UpdateChoice] = []

    func append(_ choice: UpdateChoice) {
        choices.append(choice)
    }
}
