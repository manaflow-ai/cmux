import AppKit
import CmuxNextAgentPane
import CmuxNextBrowserAutomation
import CmuxNextControl
import CmuxNextSettings
import Foundation
import WebKit

/// A local-only, focus-free render capture for the MCP process's own chat (Lucas 2026-10-19).
@MainActor
final class RenderPreviewControl {
    private var inFlight = 0
    private let dataStore = WKWebsiteDataStore.nonPersistent()

    func methods(services: AppServices) -> [ControlMethod] {
        [
            // WebKit is main-actor-only; rendering suspends outside the bounded mutation queue.
            .async("agent.render_preview") { [weak self, weak services] call in
                guard let self else { throw CancellationError() }
                return try await self.capture(call.params, services: services)
            }.withDeadline(.fixed(.seconds(12))),
        ]
    }

    /// Restored tabs keep their acpmux id in the store record until the page changes sessions.
    func pane(for session: String, in tabs: AgentTabStore) -> AgentPaneView? {
        guard let key = tabs.tab(showing: session), let view = tabs.existingView(key),
              view.model.sessionId == session, !view.model.remoteChat else { return nil }
        return view
    }

    func capture(_ params: [String: JSONValue], services: AppServices?) async throws -> JSONValue {
        guard Set(params.keys).isSubset(of: ["agent_session", "html", "width", "after", "origin"]),
              let session = params["agent_session"]?.stringValue, !session.isEmpty,
              let html = params["html"]?.stringValue, !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              html.utf8.count <= 1 << 20 else {
            throw ControlError.invalidParams("render_preview needs its MCP agent_session and at most 1 MiB of html")
        }
        let width = params["width"]?.intValue
        if let raw = params["width"], raw != .null,
           width == nil || raw != .number(Double(width ?? 0)) || !(320...1440).contains(width ?? 0) {
            throw ControlError.invalidParams("width must be an integer from 320 to 1440")
        }
        guard let tabs = services?.agentTabs,
              let view = pane(for: session, in: tabs) else {
            throw ControlError(code: "unavailable", message: "the requesting session has no local chat pane")
        }
        return try await capture {
            try await view.renderPreview(html: html, width: width, dataStore: dataStore) { webView in
                let panel = AgentRenderPanel(viewport: webView.bounds.size, screens: NSScreen.screens.map(\.frame),
                                             privateCalls: WebKitPrivateCalls())
                panel.park(webView, webView: webView)
                return { panel.finish() }
            }
        }
    }

    func capture(_ operation: @MainActor () async throws -> String) async throws -> JSONValue {
        try Task.checkCancellation()
        guard inFlight < 2 else { throw ControlError(code: "busy", message: "two render previews are already running") }
        inFlight += 1
        defer { inFlight -= 1 }
        do {
            let json = try await operation()
            return try await Task.detached { try JSONValue.parse(Data(json.utf8)) }.value
        } catch let error as AgentPaneRenderPreviewError {
            throw ControlError(code: error.rawValue, message: error.message)
        } catch is CancellationError {
            throw ControlError(code: "timeout", message: "render preview exceeded its deadline")
        } catch {
            throw ControlError(code: "render_failed", message: "WebKit could not capture the render preview")
        }
    }
}
