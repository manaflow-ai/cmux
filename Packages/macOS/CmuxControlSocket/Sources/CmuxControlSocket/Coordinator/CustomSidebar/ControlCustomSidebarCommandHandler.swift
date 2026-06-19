public import Foundation

/// Handles the worker-lane `sidebar.custom.*` v2 commands with typed wire payloads.
public struct ControlCustomSidebarCommandHandler: Sendable {
    private let validator: any ControlCustomSidebarValidating

    /// Creates a custom-sidebar command handler.
    ///
    /// - Parameter validator: Validator used to discover and validate custom sidebars.
    public init(validator: any ControlCustomSidebarValidating) {
        self.validator = validator
    }

    /// Handles `sidebar.custom.validate`.
    ///
    /// - Parameters:
    ///   - params: Typed v2 request params.
    ///   - directory: Directory containing custom sidebar files.
    ///   - messages: App-localized socket error strings.
    /// - Returns: Typed control result matching the legacy wire shape.
    public func validate(
        params: [String: JSONValue],
        directory: URL,
        messages: ControlCustomSidebarCommandMessages
    ) -> ControlCallResult {
        let name = customSidebarName(params: params)
        if let name, name.isEmpty {
            return .err(code: "invalid_params", message: messages.invalidName, data: nil)
        }
        let report = validationReport(directory: directory, name: name)
        return .ok(reportPayload(report, directory: directory))
    }

    /// Handles `sidebar.custom.reload`.
    ///
    /// - Parameters:
    ///   - params: Typed v2 request params.
    ///   - directory: Directory containing custom sidebar files.
    ///   - messages: App-localized socket error strings.
    ///   - reload: Synchronous app-side reload callback for every reported sidebar name.
    /// - Returns: Typed control result matching the legacy wire shape.
    public func reload(
        params: [String: JSONValue],
        directory: URL,
        messages: ControlCustomSidebarCommandMessages,
        reload: ([String]) -> Void
    ) -> ControlCallResult {
        let name = customSidebarName(params: params)
        if let name, name.isEmpty {
            return .err(code: "invalid_params", message: messages.invalidName, data: nil)
        }
        let report = validationReport(directory: directory, name: name)
        let validNames = report.validNames
        let reloadNames = report.names
        if !reloadNames.isEmpty {
            reload(reloadNames)
        }
        var payload = reportPayloadObject(report, directory: directory)
        payload["reloaded_count"] = .int(Int64(validNames.count))
        payload["reloaded_names"] = .array(validNames.map { .string($0) })
        return .ok(.object(payload))
    }

    /// Handles `sidebar.custom.select`.
    ///
    /// - Parameters:
    ///   - params: Typed v2 request params.
    ///   - directory: Directory containing custom sidebar files.
    ///   - providerIDPrefix: Prefix used by the app's custom-sidebar provider ids.
    ///   - messages: App-localized socket error strings.
    ///   - select: Synchronous app-side callback that persists the selected provider.
    /// - Returns: Typed control result matching the legacy wire shape.
    public func select(
        params: [String: JSONValue],
        directory: URL,
        providerIDPrefix: String,
        messages: ControlCustomSidebarCommandMessages,
        select: (ControlCustomSidebarSelection) -> Void
    ) -> ControlCallResult {
        guard let name = customSidebarName(params: params), !name.isEmpty else {
            return .err(code: "invalid_params", message: messages.selectMissingName, data: nil)
        }

        let report = validationReport(directory: directory, name: name)
        guard let entry = report.entries.first else {
            return .ok(reportPayload(report, directory: directory))
        }
        if let errorMessage = entry.errorMessage {
            var payload = reportPayloadObject(report, directory: directory)
            payload["message"] = .string(errorMessage)
            return .ok(.object(payload))
        }

        let providerID = providerIDPrefix + name
        select(ControlCustomSidebarSelection(providerID: providerID, name: name))
        var payload = reportPayloadObject(report, directory: directory)
        payload["selected_provider_id"] = .string(providerID)
        payload["selected_name"] = .string(name)
        return .ok(.object(payload))
    }

    private func customSidebarName(params: [String: JSONValue]) -> String? {
        guard case .string(let raw)? = params["name"] else { return nil }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func validationReport(directory: URL, name: String?) -> ControlCustomSidebarValidationReport {
        validator.validate(directory: directory, name: name)
    }

    private func reportPayload(_ report: ControlCustomSidebarValidationReport, directory: URL) -> JSONValue {
        .object(reportPayloadObject(report, directory: directory))
    }

    private func reportPayloadObject(_ report: ControlCustomSidebarValidationReport, directory: URL) -> [String: JSONValue] {
        [
            "directory": .string(directory.path),
            "valid_count": .int(Int64(report.validCount)),
            "error_count": .int(Int64(report.errorCount)),
            "sidebars": .array(report.entries.map(sidebarPayload(_:))),
        ]
    }

    private func sidebarPayload(_ entry: ControlCustomSidebarValidationEntry) -> JSONValue {
        .object([
            "name": .string(entry.name),
            "path": .string(entry.path),
            "kind": .string(entry.kind),
            "ok": .bool(entry.isValid),
            "error": entry.errorMessage.map(JSONValue.string) ?? .null,
        ])
    }
}
