internal import Foundation

/// The app-focus domain (`app.focus_override.set`, `app.simulate_active`),
/// lifted byte-faithfully from the former `TerminalController.v2AppFocusOverride`
/// / `v2AppSimulateActive` bodies. Each payload is built directly as a
/// ``JSONValue`` (the typed twin of the legacy `[String: Any]` dictionaries);
/// the resulting Foundation object is identical, so the encoded wire bytes match.
extension ControlCommandCoordinator {
    /// Runs one decoded request if it belongs to the app-focus domain, returning
    /// the typed result; returns `nil` otherwise so the core dispatcher falls
    /// through to other domains.
    ///
    /// - Parameter request: The decoded request envelope.
    /// - Returns: The command result, or `nil` if not owned by this domain.
    func handleAppFocus(_ request: ControlRequest) -> ControlCallResult? {
        switch request.method {
        case "app.focus_override.set":
            return appFocusOverride(request.params)
        case "app.simulate_active":
            return appSimulateActive()
        default:
            return nil
        }
    }

    /// `app.focus_override.set` — force or clear the app-focus override.
    ///
    /// Accepts either a `state` of `active` / `inactive` / `clear` (also `none`),
    /// or a `focused` boolean (present-but-non-boolean, or explicit `null`,
    /// clears). The two acceptance paths and their error shapes are byte-faithful
    /// to the legacy body.
    func appFocusOverride(_ params: [String: JSONValue]) -> ControlCallResult {
        let override: Bool?
        if let state = string(params, "state")?.lowercased() {
            switch state {
            case "active":
                override = true
            case "inactive":
                override = false
            case "clear", "none":
                override = nil
            default:
                return .err(
                    code: "invalid_params",
                    message: "Invalid state (active|inactive|clear)",
                    data: .object(["state": .string(state)])
                )
            }
        } else if params.keys.contains("focused") {
            // Legacy: `params.keys.contains("focused")` — present (including an
            // explicit JSON null) routes here; a non-boolean or null value
            // clears the override.
            override = bool(params, "focused")
        } else {
            return .err(code: "invalid_params", message: "Missing state or focused", data: nil)
        }

        context?.controlSetAppFocusOverride(override)
        return .ok(.object(["override": override.map { JSONValue.bool($0) } ?? .null]))
    }

    /// `app.simulate_active` — re-run the app's `applicationDidBecomeActive` path.
    func appSimulateActive() -> ControlCallResult {
        context?.controlSimulateAppActive()
        return .ok(.object([:]))
    }
}
