import Foundation

@MainActor
extension AgentSessionWebRendererCoordinator {
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
                "homeTitle": String(localized: "guiMode.web.home.title", defaultValue: "GUI Mode"),
                "taskTitle": String(localized: "guiMode.web.task.title", defaultValue: "/task-worktree-pr"),
                "noProvidersFound": String(localized: "guiMode.web.noProvidersFound", defaultValue: "No agents found"),
                "promptPlaceholder": String(
                    localized: "guiMode.web.promptPlaceholder",
                    defaultValue: "What should cmux build?"
                ),
                "submit": String(localized: "guiMode.web.submit", defaultValue: "Submit"),
                "submitting": String(localized: "guiMode.web.submitting", defaultValue: "Submitting"),
                "setupCommandLabel": String(localized: "guiMode.web.setupCommandLabel", defaultValue: "Setup"),
                "taskCommandLabel": String(localized: "guiMode.web.taskCommandLabel", defaultValue: "Launch"),
                "taskPromptLabel": String(localized: "guiMode.web.taskPromptLabel", defaultValue: "Prompt"),
                "providerLabel": String(localized: "guiMode.web.providerLabel", defaultValue: "Agent"),
                "providerSearchPlaceholder": String(
                    localized: "guiMode.web.providerSearchPlaceholder",
                    defaultValue: "Search agents"
                ),
                "runtimeLabel": String(localized: "guiMode.web.runtimeLabel", defaultValue: "Runtime"),
                "errorMessage": String(
                    localized: "guiMode.web.errorMessage",
                    defaultValue: "Could not create the GUI workspace."
                )
            ]
        ]
    }

    static func handleGuiModeSubmit(
        _ request: AgentSessionBridgeRequest,
        rendererKind: AgentSessionRendererKind,
        panelId: UUID,
        workspaceId: UUID
    ) throws -> [String: String] {
        guard rendererKind == .guiMode else {
            throw AgentSessionBridgeError.unsupportedMethod(request.method)
        }
        let prompt = try request.requiredString("prompt").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            throw AgentSessionBridgeError.missingParameter("prompt")
        }
        let providerID: GuiModeProviderID
        if let rawProviderID = request.params["providerId"] as? String {
            guard let parsedProviderID = GuiModeProviderID(rawValue: rawProviderID) else {
                throw AgentSessionBridgeError.invalidProvider(rawProviderID)
            }
            providerID = parsedProviderID
        } else {
            providerID = .codex
        }
        let workspace = try GuiModeWorkspaceCoordinator.createTaskWorkspace(
            prompt: prompt,
            providerID: providerID,
            sourcePanelId: panelId,
            preferredWorkspaceId: workspaceId
        )
        return ["workspaceId": workspace.id.uuidString]
    }
}
