import CmuxAgentQuestion
import Foundation

/// Every user-facing string of the question card, localized.
struct AgentQuestionStrings {
    var other: String { String(localized: "agentQuestion.other", defaultValue: "Other…", bundle: .module) }
    var otherPlaceholder: String {
        String(localized: "agentQuestion.otherPlaceholder", defaultValue: "Type your answer", bundle: .module)
    }
    var submit: String { String(localized: "agentQuestion.submit", defaultValue: "Submit", bundle: .module) }
    var skip: String { String(localized: "agentQuestion.skip", defaultValue: "Skip", bundle: .module) }
    var chooseOne: String { String(localized: "agentQuestion.chooseOne", defaultValue: "Choose one", bundle: .module) }
    var chooseAny: String { String(localized: "agentQuestion.chooseAny", defaultValue: "Choose any", bundle: .module) }
    var hint: String {
        String(localized: "agentQuestion.hint", defaultValue: "↑↓ move · return choose · esc leave", bundle: .module)
    }
    var multiHint: String {
        String(localized: "agentQuestion.multiHint", defaultValue: "↑↓ move · space toggle · return next", bundle: .module)
    }
    var cancelled: String { String(localized: "agentQuestion.cancelled", defaultValue: "Question closed", bundle: .module) }
    var preview: String { String(localized: "agentQuestion.preview", defaultValue: "Preview", bundle: .module) }

    func pager(_ index: Int, of count: Int) -> String {
        String(format: String(localized: "agentQuestion.pager", defaultValue: "%1$d of %2$d", bundle: .module), index, count)
    }

    func answeredBy(_ respondent: AgentQuestionAnswer.Respondent?) -> String {
        guard let respondent else {
            return String(localized: "agentQuestion.answered", defaultValue: "Answered", bundle: .module)
        }
        if let device = respondent.device, respondent.isRemote {
            return String(format: String(localized: "agentQuestion.answeredOnDevice", defaultValue: "Answered on %@", bundle: .module), device)
        }
        if let name = respondent.displayName {
            return String(format: String(localized: "agentQuestion.answeredBy", defaultValue: "Answered by %@", bundle: .module), name)
        }
        return String(localized: "agentQuestion.answered", defaultValue: "Answered", bundle: .module)
    }

    /// VoiceOver: "Option 2 of 3, API keys".
    func optionPosition(_ index: Int, of count: Int) -> String {
        String(format: String(localized: "agentQuestion.optionPosition", defaultValue: "Option %1$d of %2$d", bundle: .module), index, count)
    }
}
