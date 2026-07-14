import Foundation

enum BrowserDesignModeSendError: LocalizedError {
    case invalidRuntimeResponse
    case terminalUnavailable

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
        }
    }
}
