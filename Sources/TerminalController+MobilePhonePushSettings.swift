import Foundation

extension TerminalController {
    /// Enqueues a test alert through the same admission and durable delivery
    /// queue as a terminal notification, preserving the current badge count.
    func v2MobilePhonePushTest() -> V2CallResult {
        let admission = PhonePushClient.shared.forwardTest(
            badgeCount: TerminalNotificationStore.shared.unreadNotificationCount
        )
        return .ok(["stage": admission.testStageRawValue])
    }

    /// Atomically updates the Mac-owned phone-forwarding privacy gates.
    ///
    /// The mobile transport applies its same-account authorization before this
    /// handler runs. Validation completes before any default is mutated, so a
    /// malformed partial request cannot leave the gates half-applied.
    func v2MobilePhonePushSettingsUpdate(
        params: [String: Any],
        defaults: UserDefaults = .standard
    ) -> V2CallResult {
        let forwardingEnabled: Bool?
        if params.keys.contains("forwarding_enabled") {
            guard let value = params["forwarding_enabled"] as? Bool else {
                return .err(
                    code: "invalid_params",
                    message: "forwarding_enabled must be a boolean",
                    data: nil
                )
            }
            forwardingEnabled = value
        } else {
            forwardingEnabled = nil
        }

        let hideContent: Bool?
        if params.keys.contains("hide_content") {
            guard let value = params["hide_content"] as? Bool else {
                return .err(
                    code: "invalid_params",
                    message: "hide_content must be a boolean",
                    data: nil
                )
            }
            hideContent = value
        } else {
            hideContent = nil
        }

        let mode: PhoneForwardingMode?
        if params.keys.contains("mode") {
            guard let rawMode = params["mode"] as? String,
                  let value = PhoneForwardingMode(rawValue: rawMode) else {
                return .err(
                    code: "invalid_params",
                    message: "mode must be onlyWhenAway or always",
                    data: nil
                )
            }
            mode = value
        } else {
            mode = nil
        }

        guard forwardingEnabled != nil || hideContent != nil || mode != nil else {
            return .err(
                code: "invalid_params",
                message: "At least one phone push setting is required",
                data: nil
            )
        }

        let configuration = PhonePushClient.shared.updateSettings(
            forwardingEnabled: forwardingEnabled,
            mode: mode,
            hideContent: hideContent,
            defaults: defaults
        )
        return .ok([
            "forwarding_enabled": configuration.forwardingEnabled,
            "mode": configuration.mode.rawValue,
            "hide_content": configuration.hideContent,
        ])
    }
}
