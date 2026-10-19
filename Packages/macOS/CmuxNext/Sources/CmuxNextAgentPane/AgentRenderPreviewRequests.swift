package import CmuxNextSettings
import Foundation
package import WebKit

/// Validates and limits the local chat render capture independently of its control transport.
@MainActor
package final class AgentRenderPreviewRequests {
    private var inFlight = 0
    private let dataStore = WKWebsiteDataStore.nonPersistent()

    package init() {}

    /// Restored tabs keep their acpmux id in the store record until the page changes sessions.
    package func pane(for session: String, view: (String) -> AgentPaneView?) -> AgentPaneView? {
        guard let view = view(session), view.model.sessionId == session, !view.model.remoteChat else { return nil }
        return view
    }

    /// Captures the requesting session's local pane after validating the transport parameters.
    package func capture(_ params: [String: JSONValue], pane: @MainActor (String) -> AgentPaneView?,
                         park: @escaping @MainActor (WKWebView) -> (@MainActor () -> Void)) async throws -> JSONValue {
        guard Set(params.keys).isSubset(of: ["agent_session", "html", "width", "after", "origin"]),
              let session = params["agent_session"]?.stringValue, !session.isEmpty,
              let html = params["html"]?.stringValue, !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              html.utf8.count <= 1 << 20 else {
            throw AgentRenderPreviewFailure(code: "invalid_params", message: "render_preview needs its MCP agent_session and at most 1 MiB of html")
        }
        let width = params["width"]?.intValue
        if let raw = params["width"], raw != .null,
           width == nil || raw != .number(Double(width ?? 0)) || !(320...1440).contains(width ?? 0) {
            throw AgentRenderPreviewFailure(code: "invalid_params", message: "width must be an integer from 320 to 1440")
        }
        guard let view = self.pane(for: session, view: pane) else {
            throw AgentRenderPreviewFailure(code: "unavailable", message: "the requesting session has no local chat pane")
        }
        return try await capture {
            try await view.renderPreview(html: html, width: width, dataStore: dataStore, park: park)
        }
    }

    package func capture(_ operation: @MainActor () async throws -> String) async throws -> JSONValue {
        try Task.checkCancellation()
        guard inFlight < 2 else { throw AgentRenderPreviewFailure(code: "busy", message: "two render previews are already running") }
        inFlight += 1
        defer { inFlight -= 1 }
        do {
            let json = try await operation()
            return try await Task.detached { try JSONValue.parse(Data(json.utf8)) }.value
        } catch let error as AgentPaneRenderPreviewError {
            throw AgentRenderPreviewFailure(code: error.rawValue, message: error.message)
        } catch is CancellationError {
            throw AgentRenderPreviewFailure(code: "timeout", message: "render preview exceeded its deadline")
        } catch {
            throw AgentRenderPreviewFailure(code: "render_failed", message: "WebKit could not capture the render preview")
        }
    }
}
