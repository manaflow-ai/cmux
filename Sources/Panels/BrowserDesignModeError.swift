import Foundation

enum BrowserDesignModeError: LocalizedError, Equatable {
    case invalidRuntimeResponse
    case captureChanged
    case operationTimedOut

    var errorDescription: String? {
        switch self {
        case .invalidRuntimeResponse:
            String(
                localized: "browser.designMode.error.invalidRuntimeResponse",
                defaultValue: "The page returned invalid design data."
            )
        case .captureChanged:
            String(
                localized: "browser.designMode.error.captureChanged",
                defaultValue: "The selected element moved during capture. Try again when the page is still."
            )
        case .operationTimedOut:
            String(
                localized: "browser.designMode.error.operationTimedOut",
                defaultValue: "The page stopped responding. Reload it and try again."
            )
        }
    }
}
