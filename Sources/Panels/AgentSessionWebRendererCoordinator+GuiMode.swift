import Foundation
import WebKit

@MainActor
extension AgentSessionWebRendererCoordinator {
    /// Installs the same localized state as app.context before any page script runs.
    static func guiModeBootstrapScript(
        state: GuiModePanelState,
        workspaceId: UUID,
        workingDirectory: String?
    ) -> WKUserScript? {
        let payload: [String: Any] = [
            "context": guiModeContextPayload(
                page: state.page,
                prompt: state.prompt,
                selectedProviderID: state.providerID,
                selectedModelID: state.modelID,
                selectedReasoningEffort: state.reasoningEffort,
                workingDirectory: workingDirectory,
                gitBranch: AppDelegate.shared?
                    .tabManagerFor(tabId: workspaceId)?
                    .workspacesById[workspaceId]?
                    .gitBranch?
                    .branch
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
        selectedProviderID: GuiModeProviderID,
        selectedModelID: String,
        selectedReasoningEffort: String,
        workingDirectory: String?,
        gitBranch: String?
    ) -> [String: Any] {
        let selectedModel = GuiModeModelCatalog.option(provider: selectedProviderID, id: selectedModelID)
        return [
            "page": page.rawValue,
            "prompt": prompt ?? "",
            "selectedProviderId": selectedProviderID.rawValue,
            "selectedModelId": selectedModel.id,
            "selectedReasoningEffort": GuiModeModelCatalog.normalizedReasoningEffort(
                provider: selectedProviderID,
                modelID: selectedModel.id,
                requested: selectedReasoningEffort
            ),
            "workingDirectory": workingDirectory ?? "",
            "gitBranch": gitBranch ?? "",
            "models": GuiModeProviderID.allCases.flatMap { provider in
                GuiModeModelCatalog.options(for: provider).map { model in
                    [
                        "id": model.id,
                        "displayName": model.displayName,
                        "providerId": provider.rawValue,
                        "reasoningEfforts": model.reasoningEfforts
                    ] as [String: Any]
                }
            },
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
                "chatMode": String(localized: "guiMode.web.chatMode", defaultValue: "Chat"),
                "terminalMode": String(localized: "guiMode.web.terminalMode", defaultValue: "Terminal"),
                "terminalPlaceholder": String(localized: "guiMode.web.terminalPlaceholder", defaultValue: "Run a terminal command"),
                "terminalErrorMessage": String(localized: "guiMode.web.terminalErrorMessage", defaultValue: "Could not run that terminal command."),
                "modelLabel": String(localized: "guiMode.web.modelLabel", defaultValue: "Model"),
                "reasoningLabel": String(localized: "guiMode.web.reasoningLabel", defaultValue: "Reasoning"),
                "reasoningLow": String(localized: "guiMode.web.reasoningLow", defaultValue: "Low"),
                "reasoningMedium": String(localized: "guiMode.web.reasoningMedium", defaultValue: "Medium"),
                "reasoningHigh": String(localized: "guiMode.web.reasoningHigh", defaultValue: "High"),
                "reasoningExtraHigh": String(localized: "guiMode.web.reasoningExtraHigh", defaultValue: "Extra high"),
                "permissionLabel": String(localized: "guiMode.web.permissionLabel", defaultValue: "Ask for approval"),
                "permissionDefault": String(localized: "guiMode.web.permissionDefault", defaultValue: "Ask for approval"),
                "permissionFullAccess": String(localized: "guiMode.web.permissionFullAccess", defaultValue: "Full access"),
                "permissionAutoReview": String(localized: "guiMode.web.permissionAutoReview", defaultValue: "Auto-review"),
                "permissionCustom": String(localized: "guiMode.web.permissionCustom", defaultValue: "Custom"),
                "contextLabel": String(localized: "guiMode.web.contextLabel", defaultValue: "Add context"),
                "currentFolder": String(localized: "guiMode.web.currentFolder", defaultValue: "Current folder"),
                "localLabel": String(localized: "guiMode.web.localLabel", defaultValue: "Local"),
                "voiceTitle": String(localized: "guiMode.web.voiceTitle", defaultValue: "Talk to Codex"),
                "voiceDescription": String(localized: "guiMode.web.voiceDescription", defaultValue: "Use your voice to work hands-free."),
                "voiceAction": String(localized: "guiMode.web.voiceAction", defaultValue: "Try voice"),
                "folderFallback": String(localized: "guiMode.web.folderFallback", defaultValue: "Current folder"),
                "emptyTitle": String(localized: "guiMode.web.emptyTitle", defaultValue: "What should we build in cmux?"),
                "emptySubtitle": String(localized: "guiMode.web.emptySubtitle", defaultValue: "Describe an idea, fix a bug, or start with a command."),
                "modeLabel": String(localized: "guiMode.web.modeLabel", defaultValue: "Composer mode"),
                "reasoningDefault": String(localized: "guiMode.web.reasoningDefault", defaultValue: "Default"),
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
    ) async throws -> [String: String] {
        guard rendererKind == .guiMode else { throw AgentSessionBridgeError.unsupportedMethod(request.method) }
        let prompt = try request.requiredString("prompt").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { throw AgentSessionBridgeError.missingParameter("prompt") }
        let providerID = try request.params["providerId"].map { raw in
            guard let raw = raw as? String, let value = GuiModeProviderID(rawValue: raw) else {
                throw AgentSessionBridgeError.invalidProvider(String(describing: raw))
            }
            return value
        } ?? .codex
        let modelID = request.string("modelId")
        let reasoningEffort = request.string("reasoningEffort")
        let permissionMode = request.string("permissionMode")
        guard isCurrent() else { throw AgentSessionBridgeError.invalidRequest }
        await Task.yield()
        guard !Task.isCancelled, isCurrent() else { throw AgentSessionBridgeError.invalidRequest }
        let workspace = try await GuiModeWorkspaceCoordinator().createTaskWorkspace(
            prompt: prompt,
            providerID: providerID,
            modelID: modelID,
            reasoningEffort: reasoningEffort,
            permissionMode: permissionMode,
            sourcePanelId: panelId,
            preferredWorkspaceId: workspaceId,
            isRequestCurrent: isCurrent
        )
        return ["workspaceId": workspace.id.uuidString]
    }

}
