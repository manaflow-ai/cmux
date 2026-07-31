#if DEBUG
extension ControlCommandCoordinator {
    func debugBetaRemoteDefaultGet(
        _ params: [String: JSONValue]
    ) -> ControlCallResult {
        guard let debugContext else {
            return .err(code: "unavailable", message: Self.debugContextUnavailableResponse, data: nil)
        }
        let strings = debugContext.controlDebugBetaRemoteDefaultStrings()
        guard let key = string(params, "key") else {
            return .err(code: "invalid_params", message: strings.missingKey, data: nil)
        }
        guard let snapshot = debugContext.controlDebugBetaRemoteDefaultSnapshot(
            identifier: key
        ) else {
            return .err(code: "not_found", message: strings.notFound, data: nil)
        }
        return debugBetaRemoteDefaultResult(snapshot)
    }

    func debugBetaRemoteDefaultSet(
        _ params: [String: JSONValue]
    ) -> ControlCallResult {
        guard let debugContext else {
            return .err(code: "unavailable", message: Self.debugContextUnavailableResponse, data: nil)
        }
        let strings = debugContext.controlDebugBetaRemoteDefaultStrings()
        guard let key = string(params, "key") else {
            return .err(code: "invalid_params", message: strings.missingKey, data: nil)
        }
        guard let rawValue = params["value"] else {
            return .err(code: "invalid_params", message: strings.missingValue, data: nil)
        }
        let value: Bool?
        switch rawValue {
        case .bool(let enabled):
            value = enabled
        case .null:
            value = nil
        default:
            return .err(
                code: "invalid_params",
                message: strings.invalidValue,
                data: nil
            )
        }
        guard let snapshot = debugContext.controlDebugSetBetaRemoteDefault(
            identifier: key,
            value: value
        ) else {
            return .err(code: "not_found", message: strings.notFound, data: nil)
        }
        return debugBetaRemoteDefaultResult(snapshot)
    }

    private func debugBetaRemoteDefaultResult(
        _ snapshot: ControlDebugBetaRemoteDefaultSnapshot
    ) -> ControlCallResult {
        .ok(.object([
            "setting_id": .string(snapshot.settingID),
            "flag_key": .string(snapshot.flagKey),
            "user_key_present": .bool(snapshot.userKeyPresent),
            "user_value": snapshot.userValue.map { .bool($0) } ?? .null,
            "remote_default": snapshot.remoteDefault.map { .bool($0) } ?? .null,
            "effective_value": .bool(snapshot.effectiveValue),
            "source": .string(snapshot.source),
        ]))
    }
}
#endif
