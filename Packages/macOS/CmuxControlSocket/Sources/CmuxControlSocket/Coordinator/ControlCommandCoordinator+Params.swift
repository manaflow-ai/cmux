internal import Foundation

/// The typed twins of the former `TerminalControllerV2ParamParsingSupport`
/// helpers, operating on `[String: JSONValue]` (the coordinator receives typed
/// params) instead of `[String: Any]`. Each mirrors its legacy counterpart's
/// acceptance rules so moved command bodies parse identically.
///
/// App-coupled legacy helpers (`v2LocatePane` → app types, `v2PanelType` →
/// Bonsplit) are NOT here: those resolve through the domain seams or a
/// Sendable enum the app maps.
extension ControlCommandCoordinator {
    /// `v2RawString`: the raw string value, untrimmed, or `nil`.
    ///
    /// Public so the app-resident `workspace.remote.configure` witness reuses this
    /// raw read (the former app-side `jvRawString`).
    public func rawString(_ params: [String: JSONValue], _ key: String) -> String? {
        guard case .string(let value)? = params[key] else { return nil }
        return value
    }

    /// `v2OptionalTrimmedRawString`: trimmed raw string, `nil` when empty.
    func optionalTrimmedRawString(_ params: [String: JSONValue], _ key: String) -> String? {
        let trimmed = rawString(params, key)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? trimmed : nil
    }

    /// `v2StringArray`: a JSON string array (trimmed, empties dropped); a single
    /// trimmed non-empty string yields a one-element array; otherwise `nil`.
    ///
    /// Public so the app-resident `workspace.remote.configure` witness reuses this
    /// array coercion (the former app-side `jvStringArray`).
    public func stringArray(_ params: [String: JSONValue], _ key: String) -> [String]? {
        if case .array(let raw)? = params[key] {
            return raw.compactMap { element -> String? in
                guard case .string(let value) = element else { return nil }
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
        }
        if let single = string(params, key) {
            return [single]
        }
        return nil
    }

    /// `v2StringMap`: a JSON object's string-valued entries, or `nil`.
    func stringMap(_ params: [String: JSONValue], _ key: String) -> [String: String]? {
        guard case .object(let raw)? = params[key] else { return nil }
        var out: [String: String] = [:]
        for (mapKey, value) in raw {
            guard case .string(let stringValue) = value else { continue }
            out[mapKey] = stringValue
        }
        return out
    }

    /// `v2TrimmedStringMap`: the first present string-map among `keys`, with
    /// trimmed non-empty keys; `[:]` when none present.
    func trimmedStringMap(_ params: [String: JSONValue], keys: [String]) -> [String: String] {
        for key in keys {
            guard let raw = stringMap(params, key) else { continue }
            return raw.reduce(into: [String: String]()) { result, pair in
                let normalizedKey = pair.key.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !normalizedKey.isEmpty else { return }
                result[normalizedKey] = pair.value
            }
        }
        return [:]
    }

    /// `v2ActionKey`: a trimmed string lowercased with `-` mapped to `_`.
    func actionKey(_ params: [String: JSONValue], _ key: String = "action") -> String? {
        guard let action = string(params, key) else { return nil }
        return action.lowercased().replacingOccurrences(of: "-", with: "_")
    }

    /// `v2UUIDAny`: resolve a UUID (or `kind:N` ref) from a single JSON value.
    func uuidAny(_ raw: JSONValue?) -> UUID? {
        guard case .string(let value)? = raw else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let parsed = UUID(uuidString: trimmed) {
            return parsed
        }
        return handles.uuid(forRef: trimmed)
    }

    /// `v2Bool`: a JSON bool, a number (nonzero is true), or the
    /// `1/true/yes/on` / `0/false/no/off` string set; otherwise `nil`.
    func bool(_ params: [String: JSONValue], _ key: String) -> Bool? {
        switch params[key] {
        case .bool(let value):
            return value
        case .int(let value):
            return value != 0
        case .double(let value):
            return value != 0
        case .string(let value):
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "1", "true", "yes", "on":
                return true
            case "0", "false", "no", "off":
                return false
            default:
                return nil
            }
        default:
            return nil
        }
    }

    /// `v2Int`: a JSON int, a number, or a parsable string. Doubles and bools go
    /// through `NSNumber.intValue` to match the legacy `params[key] as? NSNumber`
    /// path EXACTLY — that truncates toward zero and clamps out-of-range/NaN
    /// rather than trapping (a plain `Int(Double)` traps on overflow/NaN, e.g. a
    /// caller passing `1e30` to `pane.resize`/`workspace.group.move`).
    func int(_ params: [String: JSONValue], _ key: String) -> Int? {
        switch params[key] {
        case .int(let value):
            return Int(value)
        case .double(let value):
            return NSNumber(value: value).intValue
        case .bool(let value):
            // Legacy `as? NSNumber` caught a JSON boolean and `.intValue` → 1/0.
            return NSNumber(value: value).intValue
        case .string(let value):
            return Int(value)
        default:
            return nil
        }
    }

    /// `v2Double`: a JSON double, int, bool, or parsable string. Numbers/bools go
    /// through `NSNumber.doubleValue`, matching the legacy `as? NSNumber` path
    /// (which coerced a JSON boolean to `1.0`/`0.0`).
    func double(_ params: [String: JSONValue], _ key: String) -> Double? {
        switch params[key] {
        case .double(let value):
            return value
        case .int(let value):
            return Double(value)
        case .bool(let value):
            return NSNumber(value: value).doubleValue
        case .string(let value):
            return Double(value)
        default:
            return nil
        }
    }

    /// `v2StrictInt`: an exact integer only — a non-boolean integral number or a
    /// parsable integer string; fractional or non-finite numbers are rejected.
    func strictInt(_ params: [String: JSONValue], _ key: String) -> Int? {
        strictIntValue(params[key])
    }

    /// `v2StrictIntAny`: the strict-int rule for a single JSON value.
    func strictIntValue(_ raw: JSONValue?) -> Int? {
        switch raw {
        case .int(let value):
            return Int(value)
        case .double(let value):
            guard value.isFinite, floor(value) == value else { return nil }
            return Int(exactly: value)
        case .string(let value):
            return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            // .bool is rejected (legacy guarded CFBooleanGetTypeID); .null/.array
            // /.object are non-numeric.
            return nil
        }
    }

    /// `v2NormalizedToken`: lowercased with `-`, `_`, and spaces stripped.
    func normalizedToken(_ raw: String) -> String {
        raw.replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: " ", with: "")
            .lowercased()
    }

    /// `v2InitialDividerPosition`: optional clamped `[0.1, 0.9]` divider, or an
    /// `invalid_params` error when present-but-non-numeric.
    func initialDividerPosition(
        _ params: [String: JSONValue]
    ) -> (value: Double?, error: ControlCallResult?) {
        guard hasNonNull(params, "initial_divider_position") else {
            return (nil, nil)
        }
        guard let rawPosition = double(params, "initial_divider_position"), rawPosition.isFinite else {
            return (
                nil,
                .err(code: "invalid_params", message: "initial_divider_position must be numeric", data: nil)
            )
        }
        return (min(max(rawPosition, 0.1), 0.9), nil)
    }

    // MARK: - Ref minting (typed twins of v2WorkspaceRefs / v2TabRef / …)

    /// `v2WorkspaceRefs`: stable workspace refs for a batch of ids.
    func workspaceRefs(for ids: [UUID]) -> [UUID: String] {
        var refs: [UUID: String] = [:]
        refs.reserveCapacity(ids.count)
        for id in ids {
            refs[id] = handles.ensureRef(kind: .workspace, uuid: id)
        }
        return refs
    }

    /// `v2WorkspacePaneAndSurfaceRefs`: the workspace/pane/surface ref triple.
    func workspacePaneAndSurfaceRefs(
        workspaceID: UUID,
        paneID: UUID?,
        surfaceID: UUID
    ) -> (workspaceRef: String, paneRef: String?, surfaceRef: String) {
        (
            workspaceRef: handles.ensureRef(kind: .workspace, uuid: workspaceID),
            paneRef: paneID.map { handles.ensureRef(kind: .pane, uuid: $0) },
            surfaceRef: handles.ensureRef(kind: .surface, uuid: surfaceID)
        )
    }

    /// `v2TabRef`: the legacy `tab:N` alias of a surface ref, or JSON `null`.
    func tabRef(_ uuid: UUID?) -> JSONValue {
        guard let uuid else { return .null }
        let surfaceRef = handles.ensureRef(kind: .surface, uuid: uuid)
        return .string(surfaceRef.replacingOccurrences(of: "surface:", with: "tab:"))
    }

    /// The `workspace:N` ref JSON value for a workspace id, minted through the
    /// same handle registry the coordinator uses so refs stay consistent.
    ///
    /// Public so the app-resident `workspace.remote.configure` witness shapes its
    /// `workspace_ref` payload values (the former app-side
    /// `controlWorkspaceRefValue`).
    public func workspaceRefValue(_ uuid: UUID) -> JSONValue {
        .string(handles.ensureRef(kind: .workspace, uuid: uuid))
    }

    /// The `window:N` ref JSON value (or JSON `null` when absent).
    ///
    /// Public so the app-resident `workspace.remote.configure` witness shapes its
    /// `window_ref` payload value (the former app-side `controlWindowRefValue`).
    public func windowRefValue(_ uuid: UUID?) -> JSONValue {
        guard let uuid else { return .null }
        return .string(handles.ensureRef(kind: .window, uuid: uuid))
    }

    /// The window id JSON value (or JSON `null` when absent).
    ///
    /// Public so the app-resident `workspace.remote.configure` witness shapes its
    /// `window_id` payload value (the former app-side `controlWindowOrNull`).
    public func windowIDValue(_ uuid: UUID?) -> JSONValue {
        guard let uuid else { return .null }
        return .string(uuid.uuidString)
    }
}
