internal import Foundation

/// The `system.tree` window-routing parse: the typed twin of the legacy
/// `parseV2WindowRouting` (which stays app-side for the worker-lane
/// `system.top` / `system.memory`), resolving the focused/caller identity
/// through the shared `system.identify` seam.
extension ControlCommandCoordinator {
    /// The parsed window routing for `system.tree` (the legacy
    /// `V2WindowRouting`).
    struct SystemWindowRouting {
        /// Whether `all_windows` was set.
        let includeAllWindows: Bool
        /// The explicit `window_id`, if any.
        let requestedWindowID: UUID?
        /// The identify payload's `focused` object (empty when null/absent).
        let focused: [String: JSONValue]
        /// The identify payload's `caller` object (empty when null/absent).
        let caller: [String: JSONValue]
        /// The focused window resolved from the identify payload.
        let focusedWindowID: UUID?
    }

    /// The routing parse outcome: the parsed routing, or the exact legacy
    /// `invalid_params` error to return.
    enum SystemWindowRoutingOutcome {
        /// The routing parsed.
        case routed(SystemWindowRouting)
        /// A param was invalid; return this error.
        case invalid(ControlCallResult)
    }

    /// Parses the `all_windows` / `window_id` / `caller` routing exactly as
    /// the legacy `parseV2WindowRouting` did, including its three
    /// `invalid_params` shapes.
    func systemWindowRouting(
        _ params: [String: JSONValue]
    ) -> SystemWindowRoutingOutcome {
        if params["all_windows"] != nil, bool(params, "all_windows") == nil {
            return .invalid(.err(
                code: "invalid_params",
                message: "Invalid all_windows. Pass true or false, or omit it. Use --window <id|ref|index> to target one window or --all-windows to target all windows.",
                data: nil
            ))
        }

        let includeAllWindows = bool(params, "all_windows") ?? false
        let requestedWindowID = uuid(params, "window_id")
        if params["window_id"] != nil && requestedWindowID == nil {
            return .invalid(.err(
                code: "invalid_params",
                message: "Invalid window selector. Use --window <id|ref|index> to target one window, or run `cmux list-windows` to see available windows and retry.",
                data: systemWindowSelectorDetails(params)
            ))
        }
        if includeAllWindows, requestedWindowID != nil {
            return .invalid(.err(
                code: "invalid_params",
                message: "Choose either --window <id|ref|index> or --all-windows, not both. Run `cmux list-windows` to see available windows and retry.",
                data: systemWindowSelectorDetails(params)
            ))
        }

        var identifyParams: [String: JSONValue] = [:]
        if case .object(let callerObject)? = params["caller"], !callerObject.isEmpty {
            identifyParams["caller"] = .object(callerObject)
        }
        if let requestedWindowID {
            identifyParams["window_id"] = .string(requestedWindowID.uuidString)
        }
        let identifyPayload = systemContext?.controlSystemIdentify(params: identifyParams) ?? .object([:])
        var focused: [String: JSONValue] = [:]
        var caller: [String: JSONValue] = [:]
        if case .object(let payload) = identifyPayload {
            if case .object(let focusedObject)? = payload["focused"] {
                focused = focusedObject
            }
            if case .object(let callerObject)? = payload["caller"] {
                caller = callerObject
            }
        }
        let focusedWindowID = uuidAny(focused["window_id"]) ?? uuidAny(focused["window_ref"])
        return .routed(SystemWindowRouting(
            includeAllWindows: includeAllWindows,
            requestedWindowID: requestedWindowID,
            focused: focused,
            caller: caller,
            focusedWindowID: focusedWindowID
        ))
    }

    /// The `{"window_id": …}` error detail for a present `window_id` param
    /// (the legacy `v2WindowSelectorDetails`, including its
    /// `String(describing:)` fallback for non-string values).
    func systemWindowSelectorDetails(_ params: [String: JSONValue]) -> JSONValue? {
        guard let rawWindowID = params["window_id"] else { return nil }
        if case .string(let value) = rawWindowID {
            return .object(["window_id": .string(value)])
        }
        return .object(["window_id": .string(String(describing: rawWindowID.foundationObject))])
    }

    /// The `system.tree` window-not-found error (the legacy
    /// `v2WindowNotFoundResult`).
    func systemWindowNotFound(_ params: [String: JSONValue], windowID: UUID) -> ControlCallResult {
        .err(
            code: "not_found",
            message: "Window not found. Run `cmux list-windows` to see available windows, then retry with --window <id|ref|index>.",
            data: systemWindowSelectorDetails(params)
                ?? .object(["window_id": .string(windowID.uuidString)])
        )
    }
}
