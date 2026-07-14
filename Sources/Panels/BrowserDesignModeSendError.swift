import Foundation

enum BrowserDesignModeSendError: LocalizedError, Equatable {
    case invalidRuntimeResponse
    case terminalUnavailable
    case multipleAgentTerminals
    case agentBusy
    case agentComposerNotEmpty
    case draftReplacementNotConfirmed
    case promptClearUnavailable
    case captureChanged
    case submitUnavailable
    case operationTimedOut

    var errorDescription: String? {
        switch self {
        case .invalidRuntimeResponse:
            String(
                localized: "browser.designMode.error.invalidRuntimeResponse",
                defaultValue: "The page returned invalid design data."
            )
        case .terminalUnavailable:
            String(
                localized: "browser.designMode.error.noAgentTerminal",
                defaultValue: "No agent terminal is available in this workspace."
            )
        case .multipleAgentTerminals:
            String(
                localized: "browser.designMode.error.multipleAgentTerminals",
                defaultValue: "This workspace has multiple agent terminals. Keep one agent session open, then try again."
            )
        case .agentBusy:
            String(
                localized: "browser.designMode.error.agentBusy",
                defaultValue: "Wait for the agent to finish before sending this design."
            )
        case .agentComposerNotEmpty:
            String(
                localized: "browser.designMode.error.agentComposerNotEmpty",
                defaultValue: "The agent composer already has a draft. Send or clear it before sending this design."
            )
        case .draftReplacementNotConfirmed:
            String(
                localized: "browser.designMode.error.draftReplacementNotConfirmed",
                defaultValue: "Confirm replacing the agent prompt before sending this design."
            )
        case .promptClearUnavailable:
            String(
                localized: "browser.designMode.error.promptClearUnavailable",
                defaultValue: "The agent prompt could not be prepared for this design."
            )
        case .captureChanged:
            String(
                localized: "browser.designMode.error.captureChanged",
                defaultValue: "The selected element moved during capture. Try again when the page is still."
            )
        case .submitUnavailable:
            String(
                localized: "browser.designMode.error.submitUnavailable",
                defaultValue: "The design prompt was pasted into the agent terminal but could not be submitted."
            )
        case .operationTimedOut:
            String(
                localized: "browser.designMode.error.operationTimedOut",
                defaultValue: "The page stopped responding. Reload it and try again."
            )
        }
    }
}
