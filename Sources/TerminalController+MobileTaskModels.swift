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
        return .ok([
            "models": result.models.map { model in
                var object: [String: Any] = [
                    "id": model.id,
                    "display_name": model.displayName,
                    "efforts": model.efforts.map { effort in
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
                if let defaultEffortID = model.defaultEffortID {
                    object["default_effort_id"] = defaultEffortID
                }
                return object
            },
            "source": result.source.rawValue,
        ])
    }
}
