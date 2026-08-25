import Foundation

extension TerminalController {
    @MainActor
    func v2CaffeineStatus() -> V2CallResult {
        guard let caffeineController else {
            return .err(
                code: "caffeine_unavailable",
                message: String(
                    localized: "caffeine.error.unavailable",
                    defaultValue: "Keep Mac Awake isn't available yet."
                ),
                data: nil
            )
        }
        return .ok(["enabled": caffeineController.isEnabled])
    }

    @MainActor
    func v2CaffeineSet(params: [String: Any]) -> V2CallResult {
        guard v2HasNonNullParam(params, "enabled"),
              let enabled = v2Bool(params, "enabled") else {
            return .err(
                code: "invalid_params",
                message: String(
                    localized: "caffeine.error.missingEnabled",
                    defaultValue: "Pass enabled=true or enabled=false."
                ),
                data: nil
            )
        }
        guard let caffeineController else {
            return v2CaffeineStatus()
        }
        caffeineController.setEnabled(enabled)
        return .ok(["enabled": caffeineController.isEnabled])
    }
}
