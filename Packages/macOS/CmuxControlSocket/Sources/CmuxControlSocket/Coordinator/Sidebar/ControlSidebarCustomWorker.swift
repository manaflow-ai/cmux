internal import Foundation

/// The worker-lane RPC handler for the v2 `sidebar.custom.*` control commands,
/// lifted byte-faithfully from `TerminalController.v2CustomSidebar*` /
/// `socketWorkerV2Response`.
///
/// Owns the command logic for `sidebar.custom.validate`, `sidebar.custom.reload`,
/// and `sidebar.custom.select`: param parsing, the empty-name branching, and the
/// reply payload formatting. The validation, the reload/select side effects, and
/// the localized error strings are reached strictly through the
/// ``ControlSidebarCustomReading`` seam (they touch the `CmuxSwiftRenderUI`
/// validator and the app's `CmuxExtensionSidebarSelection`, which this package
/// must not import). It does no socket I/O and never imports the app target.
///
/// ## Isolation
///
/// `Sendable` and `async`, NOT `@MainActor`: these commands run on the
/// nonisolated socket-worker lane (`runsOnSocketWorker`). The legacy bodies were
/// `nonisolated` and ran the SwiftUI-interpreter validation on the worker
/// thread, hopping to main via `v2MainSync` only for the reload/select side
/// effects. The seam preserves that: ``ControlSidebarCustomReading/validate(name:)``
/// runs on the worker thread and the `reload`/`select` seam members hop to main
/// internally. The wire payloads are byte-identical to the legacy ones (see
/// ``ControlSidebarCustomWorker/reportPayload(_:)`` for the per-field mapping).
public struct ControlSidebarCustomWorker: Sendable {
    /// The live custom-sidebar seam. Injected at construction.
    private let reading: any ControlSidebarCustomReading

    /// Creates a worker.
    ///
    /// - Parameter reading: The custom-sidebar seam to read/drive.
    public init(reading: any ControlSidebarCustomReading) {
        self.reading = reading
    }

    /// Runs one decoded request if it is a `sidebar.custom.*` worker-lane
    /// command, returning the typed result; returns `nil` for any other method
    /// so the caller can fall through.
    ///
    /// - Parameter request: The decoded request envelope.
    /// - Returns: The command result, or `nil` if not an owned method.
    public func handle(_ request: ControlRequest) async -> ControlCallResult? {
        switch request.method {
        case "sidebar.custom.validate":
            return validate(request.params)
        case "sidebar.custom.reload":
            return await reload(request.params)
        case "sidebar.custom.select":
            return await select(request.params)
        default:
            return nil
        }
    }

    /// `sidebar.custom.validate` — validates the discovered or requested custom
    /// sidebars.
    private func validate(_ params: [String: JSONValue]) -> ControlCallResult {
        let name = sidebarName(params)
        if let name, name.isEmpty {
            return .err(code: "invalid_params", message: reading.strings().invalidName, data: nil)
        }
        return .ok(.object(reportPayload(reading.validate(name: name))))
    }

    /// `sidebar.custom.reload` — validates and triggers a reload for every
    /// reported sidebar.
    private func reload(_ params: [String: JSONValue]) async -> ControlCallResult {
        let name = sidebarName(params)
        if let name, name.isEmpty {
            return .err(code: "invalid_params", message: reading.strings().invalidName, data: nil)
        }
        let report = await reading.reload(name: name)
        var payload = reportPayload(report)
        payload["reloaded_count"] = .int(Int64(report.validNames.count))
        payload["reloaded_names"] = .array(report.validNames.map { .string($0) })
        return .ok(.object(payload))
    }

    /// `sidebar.custom.select` — validates and, when the first matching sidebar
    /// is valid, applies the selection.
    private func select(_ params: [String: JSONValue]) async -> ControlCallResult {
        guard let name = sidebarName(params), !name.isEmpty else {
            return .err(code: "invalid_params", message: reading.strings().selectMissingName, data: nil)
        }
        switch await reading.select(name: name) {
        case .report(let report):
            return .ok(.object(reportPayload(report)))
        case .entryError(let report, let message):
            var payload = reportPayload(report)
            payload["message"] = .string(message)
            return .ok(.object(payload))
        case .selected(let report, let providerID, let selectedName):
            var payload = reportPayload(report)
            payload["selected_provider_id"] = .string(providerID)
            payload["selected_name"] = .string(selectedName)
            return .ok(.object(payload))
        }
    }

    // MARK: - Helpers

    /// The trimmed `name` param (the legacy `v2CustomSidebarName`): a JSON
    /// string trimmed of whitespace (empty string preserved as `""`), or `nil`
    /// when the key is absent or not a JSON string. The empty-vs-nil distinction
    /// drives the per-command branching, so this is a faithful twin of the
    /// legacy parser rather than the coordinator's `string(_:_:)` (which folds
    /// whitespace-only to `nil`).
    private func sidebarName(_ params: [String: JSONValue]) -> String? {
        guard case .string(let raw)? = params["name"] else { return nil }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Builds the shared `sidebar.custom.*` reply payload (the legacy
    /// `v2CustomSidebarReportPayload`): directory, counts, and the per-sidebar
    /// array. `error` is JSON `null` when absent (the legacy `v2OrNull`).
    private func reportPayload(_ report: ControlSidebarCustomReport) -> [String: JSONValue] {
        [
            "directory": .string(report.directoryPath),
            "valid_count": .int(Int64(report.validCount)),
            "error_count": .int(Int64(report.errorCount)),
            "sidebars": .array(report.entries.map { entry in
                .object([
                    "name": .string(entry.name),
                    "path": .string(entry.path),
                    "kind": .string(entry.kindRawValue),
                    "ok": .bool(entry.isValid),
                    "error": entry.errorMessage.map { JSONValue.string($0) } ?? .null,
                ])
            }),
        ]
    }
}
