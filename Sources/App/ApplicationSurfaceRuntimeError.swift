import Foundation

enum ApplicationSurfaceRuntimeError: LocalizedError, Equatable, Sendable {
    case permissionRequired
    case windowUnavailable
    case helperUnavailable
    case pointOutsideContent
    case captureUnavailable
    case resourceLimit
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .permissionRequired:
            String(
                localized: "applicationSurface.error.permissionRequired",
                defaultValue: "Application panes need Accessibility and Screen Recording access."
            )
        case .windowUnavailable:
            String(
                localized: "applicationSurface.error.windowUnavailable",
                defaultValue: "The selected application window is no longer available."
            )
        case .helperUnavailable:
            String(
                localized: "applicationSurface.error.helperUnavailable",
                defaultValue: "The cmux Computer Use helper is unavailable."
            )
        case .pointOutsideContent, .captureUnavailable:
            nil
        case .resourceLimit:
            String(
                localized: "applicationSurface.error.resourceLimit",
                defaultValue: "Application pane capacity is full. Close another application pane and try again."
            )
        case .invalidResponse:
            String(
                localized: "applicationSurface.error.invalidResponse",
                defaultValue: "The cmux Computer Use helper returned an invalid response."
            )
        }
    }
}
