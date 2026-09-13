import Foundation
import WebKit

@MainActor
extension AgentSessionWebRendererCoordinator {
    /// Installs the same localized state as app.context before any page script runs.
    static func guiModeBootstrapScript(state: GuiModePanelState) -> WKUserScript? {
        let payload: [String: Any] = [
            "context": guiModeContextPayload(
                page: state.page, prompt: state.prompt, selectedProviderID: state.providerID
            ),
            "loadingMessage": String(localized: "agentSession.web.status.loading", defaultValue: "Loading"),
            "errorMessage": String(localized: "agentSession.web.error.requestFailed", defaultValue: "Native bridge request failed.")
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return WKUserScript(
            source: "window.cmuxGuiModeBootstrap = \(json);",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
    }

    static func guiModeContextPayload(
        page: GuiModePanelPage,
        prompt: String?,
        selectedProviderID: GuiModeProviderID
    ) -> [String: Any] {
        [
            "page": page.rawValue,
            "prompt": prompt ?? "",
            "selectedProviderId": selectedProviderID.rawValue,
            "providers": GuiModeProviderID.allCases.map { provider in
                [
                    "id": provider.rawValue,
                    "displayName": provider.displayName,
                    "accentColor": provider.accentColor,
                    "detail": provider.detail,
                    "runtimeMode": provider.runtimeMode,
                    "supportLabel": provider.supportLabel,
                    "setupCommand": provider.setupCommand,
                    "taskCommandPreview": provider.taskCommandPreview,
                    "capabilities": provider.capabilityLabels
                ] as [String: Any]
            },
            "copy": [
                "cancel": String(localized: "guiMode.web.cancel", defaultValue: "Cancel"),
                "cancellationUnconfirmed": String(localized: "guiMode.web.cancellationUnconfirmed", defaultValue: "Could not confirm cancellation. Try Cancel again before submitting another task."),
                "homeTitle": String(localized: "guiMode.web.home.title", defaultValue: "GUI Mode"),
                "taskTitle": String(localized: "guiMode.web.task.title", defaultValue: "/task-worktree-pr"),
                "noProvidersFound": String(localized: "guiMode.web.noProvidersFound", defaultValue: "No agents found"),
                "promptPlaceholder": String(localized: "guiMode.web.promptPlaceholder", defaultValue: "What should cmux build?"),
                "submit": String(localized: "guiMode.web.submit", defaultValue: "Submit"),
                "submitting": String(localized: "guiMode.web.submitting", defaultValue: "Submitting"),
                "setupCommandLabel": String(localized: "guiMode.web.setupCommandLabel", defaultValue: "Setup"),
                "taskCommandLabel": String(localized: "guiMode.web.taskCommandLabel", defaultValue: "Launch"),
                "taskPromptLabel": String(localized: "guiMode.web.taskPromptLabel", defaultValue: "Prompt"),
                "providerLabel": String(localized: "guiMode.web.providerLabel", defaultValue: "Agent"),
                "providerSearchPlaceholder": String(localized: "guiMode.web.providerSearchPlaceholder", defaultValue: "Search agents"),
                "runtimeLabel": String(localized: "guiMode.web.runtimeLabel", defaultValue: "Runtime"),
                "errorMessage": String(localized: "guiMode.web.errorMessage", defaultValue: "Could not create the GUI workspace.")
            ]
        ]
    }

    static func handleGuiModeSubmit(
        _ request: AgentSessionBridgeRequest,
        rendererKind: AgentSessionRendererKind,
        panelId: UUID,
        workspaceId: UUID,
        isCurrent: @MainActor @escaping () -> Bool
    ) throws -> [String: String] {
        guard rendererKind == .guiMode else { throw AgentSessionBridgeError.unsupportedMethod(request.method) }
        let prompt = try request.requiredString("prompt").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { throw AgentSessionBridgeError.missingParameter("prompt") }
        let providerID = try request.params["providerId"].map { raw in
            guard let raw = raw as? String, let value = GuiModeProviderID(rawValue: raw) else {
                throw AgentSessionBridgeError.invalidProvider(String(describing: raw))
            }
            return value
        } ?? .codex
        guard isCurrent() else { throw AgentSessionBridgeError.invalidRequest }
        let workspace = try GuiModeWorkspaceCoordinator().createTaskWorkspace(
            prompt: prompt,
            providerID: providerID,
            sourcePanelId: panelId,
            preferredWorkspaceId: workspaceId,
            isRequestCurrent: isCurrent
        )
        return ["workspaceId": workspace.id.uuidString]
    }
}
