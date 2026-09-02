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
        return .ok(Self.caffeineStatusPayload(caffeineController))
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
        var lockScreen: Bool?
        if v2HasNonNullParam(params, "lock_screen") {
            guard let value = v2Bool(params, "lock_screen") else {
                return .err(
                    code: "invalid_params",
                    message: String(
                        localized: "caffeine.error.invalidLockScreen",
                        defaultValue: "lock_screen must be true or false."
                    ),
                    data: nil
                )
            }
            lockScreen = value
        }
        var lockMac: Bool?
        if v2HasNonNullParam(params, "lock_mac") {
            guard let value = v2Bool(params, "lock_mac") else {
                return .err(
                    code: "invalid_params",
                    message: String(
                        localized: "caffeine.error.invalidLockMac",
                        defaultValue: "lock_mac must be true or false."
                    ),
                    data: nil
                )
            }
            lockMac = value
        }
        guard let caffeineController else {
            return v2CaffeineStatus()
        }
        caffeineController.setEnabled(enabled, lockScreen: lockScreen, lockMac: lockMac)
        return .ok(Self.caffeineStatusPayload(caffeineController))
    }

    @MainActor
    private static func caffeineStatusPayload(_ controller: CaffeineController) -> [String: Any] {
        [
            "enabled": controller.isEnabled,
            "lock_screen_active": controller.isLockScreenPresented
        ]
    }
}
