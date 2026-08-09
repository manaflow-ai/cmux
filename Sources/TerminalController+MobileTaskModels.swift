import CmuxControlSocket
import Foundation

extension TerminalController {
    /// Handles one `mobile.task.models.list` provider discovery request.
    nonisolated func v2MobileTaskModelsList(
        params: [String: Any]
    ) async -> V2CallResult {
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
            "models": result.models.map {
                [
                    "id": $0.id,
                    "display_name": $0.displayName,
                ]
            },
            "source": result.source.rawValue,
        ])
    }
}
