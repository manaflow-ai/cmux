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
        case .disabled: String(localized: "agentPane.renderPreview.disabled", defaultValue: "render preview or live render is disabled in this pane", bundle: .module)
        case .busy: String(localized: "agentPane.renderPreview.busy", defaultValue: "a render preview is already running in this pane", bundle: .module)
        case .timeout: String(localized: "agentPane.renderPreview.timeout", defaultValue: "render preview exceeded its deadline", bundle: .module)
        case .notLaidOut: String(localized: "agentPane.renderPreview.notLaidOut", defaultValue: "the chat or render frame is not laid out yet", bundle: .module)
        case .failed: String(localized: "agentPane.renderPreview.failed", defaultValue: "WebKit could not capture the render preview", bundle: .module)
        }
    }
}
