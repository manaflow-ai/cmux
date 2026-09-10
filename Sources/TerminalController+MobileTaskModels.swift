import CmuxControlSocket
import Foundation

extension TerminalController {
    nonisolated static var mobileTaskComposerFeatureEnabled: Bool {
        CmuxFeatureFlags.offMainEffectiveValue(
            for: CmuxFeatureFlags.mobileTaskComposerFlag
        )
    }

    nonisolated static var mobileTaskComposerDisabledResult: V2CallResult {
        .err(
            code: "capability_disabled",
            message: String(
                localized: "mobile.taskComposer.error.capabilityDisabled",
                defaultValue: "Task Composer is disabled on this Mac"
            ),
            data: ["capability": MobileHostService.taskCreateCapability]
        )
    }

    /// Handles one `mobile.task.models.list` provider discovery request.
    nonisolated func v2MobileTaskModelsList(
        params: [String: Any]
    ) async -> V2CallResult {
        guard Self.mobileTaskComposerFeatureEnabled else {
            return Self.mobileTaskComposerDisabledResult
        }
        guard let rawProvider = v2RawString(params, "provider"),
              let provider = MobileTaskModelProvider(rawValue: rawProvider) else {
            return .err(
                code: "invalid_params",
                message: "provider must be claude, codex, or opencode",
                data: nil
            )
        }
        let result = await mobileTaskModelDiscovery.models(for: provider)
        func modelObject(
            id: String,
            displayName: String,
            efforts: [(id: String, displayName: String, description: String?)],
            defaultEffortID: String?
        ) -> [String: Any] {
            var object: [String: Any] = [
                "id": id,
                "display_name": displayName,
                "efforts": efforts.map { effort in
                    var effortObject: [String: Any] = [
                        "id": effort.id,
                        "display_name": effort.displayName,
                    ]
                    if let description = effort.description {
                        effortObject["description"] = description
                    }
                    return effortObject
                },
            ]
            if let defaultEffortID {
                object["default_effort_id"] = defaultEffortID
            }
            return object
        }
        var response: [String: Any] = [
            "models": result.models.map { model in
                modelObject(
                    id: model.id,
                    displayName: model.displayName,
                    efforts: model.efforts.map {
                        (id: $0.id, displayName: $0.displayName, description: $0.description)
                    },
                    defaultEffortID: model.defaultEffortID
                )
            },
            "source": result.source.rawValue,
        ]
        if let error = result.error {
            response["error"] = error.rawValue
        }
        if let defaultModel = result.defaultModel {
            response["default_model"] = modelObject(
                id: defaultModel.id,
                displayName: defaultModel.displayName,
                efforts: defaultModel.efforts.map {
                    (id: $0.id, displayName: $0.displayName, description: $0.description)
                },
                defaultEffortID: defaultModel.defaultEffortID
            )
        }
        return .ok(response)
    }
}
