import Foundation

/// Stable failures shared with the app socket, without exposing WebKit implementation text.
public enum AgentPaneRenderPreviewError: String, Error {
    case disabled
    case busy
    case timeout
    case notLaidOut = "not_laid_out"
    case failed = "render_failed"

    /// Agent-facing context for a failed preview.
    public var message: String {
        switch self {
        case .disabled: "render preview or live render is disabled in this pane"
        case .busy: "a render preview is already running in this pane"
        case .timeout: "render preview exceeded its deadline"
        case .notLaidOut: "the chat or render frame is not laid out yet"
        case .failed: "WebKit could not capture the render preview"
        }
    }
}
