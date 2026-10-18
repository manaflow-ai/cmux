#if DEBUG
import CmuxCloud
import Foundation

/// The `debug.cloud_secrets.*` socket verbs' view of the Cloud Secrets sheet.
///
/// Evaluators drive the sheet without Accessibility or Screen Recording grants:
/// `interact` calls the same model methods the sheet's controls call, and
/// `state` reports what the sheet shows as names and labels. A value goes into
/// the model's editor and never comes back out: the snapshot carries no value
/// field, and ``redacting(_:values:)`` scrubs any value still held by the
/// model from every string as a second guard.
enum CloudDebugSecretsProbe {
    /// One `debug.cloud_secrets.interact` request, parsed from socket params.
    enum Action: Equatable, Sendable {
        case selectTab(CloudSecretsSheetPresentation.Tab)
        /// nil lists every project on the Project tab.
        case selectProject(String?)
        case openAdd(presetName: String?)
        case openReplace(name: String, scope: CloudSecretScope?)
        case setEditorName(String)
        case setEditorValue(String)
        case setEditorProject(String)
        case save
        case cancel
        case importText(text: String, sourceName: String?)
        case importCommit
        case importCancel
        case remove(name: String, scope: CloudSecretScope?, confirm: Bool)
        case cancelRemove
        case syncNow
        case selectRow(name: String, scope: CloudSecretScope?)
        case setRequirement(name: String)

        /// The wire name, echoed in responses.
        var name: String {
            switch self {
            case .selectTab: return "select_tab"
            case .selectProject: return "select_project"
            case .openAdd: return "open_add"
            case .openReplace: return "open_replace"
            case .setEditorName: return "set_editor_name"
            case .setEditorValue: return "set_editor_value"
            case .setEditorProject: return "set_editor_project"
            case .save: return "save"
            case .cancel: return "cancel"
            case .importText: return "import_text"
            case .importCommit: return "import_commit"
            case .importCancel: return "import_cancel"
            case .remove: return "remove"
            case .cancelRemove: return "cancel_remove"
            case .syncNow: return "sync_now"
            case .selectRow: return "select_row"
            case .setRequirement: return "set_requirement"
            }
        }

        /// Whether the model method is async: the socket starts it and the
        /// caller polls `state` until `busy` is false.
        var isAsync: Bool {
            switch self {
            case .save, .importText, .importCommit, .syncNow: return true
            case .remove(_, _, let confirm): return confirm
            default: return false
            }
        }

        static let names = [
            "select_tab", "select_project", "open_add", "open_replace", "set_editor_name",
            "set_editor_value", "set_editor_project", "save", "cancel", "import_text",
            "import_commit", "import_cancel", "remove", "cancel_remove", "sync_now",
            "select_row", "set_requirement",
        ]
    }

    /// Why a request did not parse; `message` never contains a param value.
    struct ParamError: Error, Equatable {
        let message: String
    }

    // MARK: Parsing

    static func parseAction(_ params: [String: Any]) -> Result<Action, ParamError> {
        guard let action = string(params, "action") else {
            return .failure(ParamError(message: "action is required; one of \(Action.names.joined(separator: ", "))"))
        }
        switch action {
        case "select_tab":
            guard let raw = string(params, "tab"), let tab = CloudSecretsSheetPresentation.Tab(rawValue: raw) else {
                return .failure(ParamError(message: "tab must be one of all, project, machine"))
            }
            return .success(.selectTab(tab))
        case "select_project":
            return .success(.selectProject(string(params, "project_key")))
        case "open_add":
            return .success(.openAdd(presetName: string(params, "preset_name")))
        case "open_replace":
            return named(params) { .openReplace(name: $0, scope: $1) }
        case "set_editor_name":
            guard let name = rawString(params, "name") else { return .failure(ParamError(message: "name is required")) }
            return .success(.setEditorName(name))
        case "set_editor_value":
            guard let value = rawString(params, "value") else { return .failure(ParamError(message: "value is required")) }
            return .success(.setEditorValue(value))
        case "set_editor_project":
            guard let project = rawString(params, "project") else { return .failure(ParamError(message: "project is required")) }
            return .success(.setEditorProject(project))
        case "save": return .success(.save)
        case "cancel": return .success(.cancel)
        case "import_text":
            guard let text = rawString(params, "text") else { return .failure(ParamError(message: "text is required")) }
            return .success(.importText(text: text, sourceName: string(params, "source_name")))
        case "import_commit": return .success(.importCommit)
        case "import_cancel": return .success(.importCancel)
        case "remove":
            let confirm = bool(params["confirm"]) ?? false
            return named(params) { .remove(name: $0, scope: $1, confirm: confirm) }
        case "cancel_remove": return .success(.cancelRemove)
        case "sync_now": return .success(.syncNow)
        case "select_row":
            return named(params) { .selectRow(name: $0, scope: $1) }
        case "set_requirement":
            guard let name = string(params, "name") else { return .failure(ParamError(message: "name is required")) }
            return .success(.setRequirement(name: name))
        default:
            return .failure(ParamError(message: "unknown action; one of \(Action.names.joined(separator: ", "))"))
        }
    }

    private static func named(
        _ params: [String: Any],
        _ make: (String, CloudSecretScope?) -> Action
    ) -> Result<Action, ParamError> {
        guard let name = string(params, "name") else { return .failure(ParamError(message: "name is required")) }
        guard let rawScope = string(params, "scope") else { return .success(make(name, nil)) }
        guard let scope = CloudSecretScope(wireValue: rawScope) else {
            return .failure(ParamError(message: "scope must be all, project:<key> or machine:<id>"))
        }
        return .success(make(name, scope))
    }

    /// A trimmed, non-empty string param.
    static func string(_ params: [String: Any], _ key: String) -> String? {
        guard let raw = params[key] as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// A string param as typed, so a field can be set to spaces or emptied.
    private static func rawString(_ params: [String: Any], _ key: String) -> String? {
        params[key] as? String
    }

    static func bool(_ raw: Any?) -> Bool? {
        switch raw {
        case let value as Bool: return value
        case let value as NSNumber: return value.boolValue
        case let value as String:
            switch value.lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no": return false
            default: return nil
            }
        default: return nil
        }
    }

    // MARK: Lookup

    /// The record a name (and optional scope) names: the visible tab first,
    /// then every scope, as a row the sheet could show.
    @MainActor
    static func record(named name: String, scope: CloudSecretScope?, in model: CloudSecretsSheetModel) -> CloudSecretRecord? {
        let matches: (CloudSecretRecord) -> Bool = { $0.name == name && (scope == nil || $0.scope == scope) }
        return model.visibleRecords.first(where: matches) ?? model.records.first(where: matches)
    }

    // MARK: State

    /// Which body the sheet shows, mirroring `CloudSecretsSheet.content`.
    @MainActor
    static func visibleBody(_ model: CloudSecretsSheetModel) -> String {
        switch model.phase {
        case .loading: return "loading"
        case .loadFailed: return "load_failed"
        case .ready:
            if model.importDraft != nil { return "import_preview" }
            if model.isEmptyVault, model.editor == nil { return "empty_state" }
            return "list"
        }
    }

    /// Everything the sheet shows, as names and labels. No value field exists
    /// here; values still held by the model are scrubbed from every string.
    @MainActor
    static func state(_ model: CloudSecretsSheetModel, busy: Bool) -> [String: Any] {
        let labels = model.machineLabels
        let body = visibleBody(model)
        var tabCounts: [String: Int] = [:]
        for tab in CloudSecretsSheetPresentation.Tab.allCases { tabCounts[tab.rawValue] = model.count(for: tab) }
        var state: [String: Any] = [:]
        state["open"] = true
        state["busy"] = busy
        state["machine_mode"] = model.isMachineMode
        state["tab"] = model.tab.rawValue
        state["tab_counts"] = tabCounts
        state["body"] = body
        state["empty_state_visible"] = body == "empty_state"
        state["can_add"] = model.canAdd
        state["project_keys"] = model.projectKeys
        state["available_presets"] = model.availablePresets.map(\.name)
        state["rows"] = model.visibleRecords.map { rowState($0, model: model) }
        state["unset_requirements"] = model.unsetRequirements.map(\.name)
        state["has_modal_card"] = model.hasModalCard
        state["machine_id"] = model.machineID
        state["machine_label"] = model.machineLabel
        state["project_key"] = model.projectKey
        state["selected_row"] = model.selectedRecord?.name
        state["pending_removal"] = model.pendingRemoval.map { ["name": $0.name, "scope": $0.scope.wireValue] }
        state["editor"] = model.editor.map { editorState($0, model: model) }
        state["import_preview"] = model.importDraft.map { importState($0, labels: labels) }
        state["errors"] = errors(model)
        if model.isMachineMode {
            var machine: [String: Any] = [
                "is_syncing": model.isSyncing,
                "is_delivering": model.isDelivering,
                "summary": CloudSecretsSheetPresentation.machineSummary(model.statusRows, isDelivering: model.isDelivering),
                "did_sync": model.didSync,
                "extra_names": model.extraNames,
                "needs_sync": CloudSecretsSheetPresentation.needsSync(model.statusRows),
                "status_rows": model.statusRows.map { ["name": $0.name, "state": $0.state.rawValue] },
            ]
            machine["delivered"] = CloudSecretsSheetPresentation.deliveredLabel(model.delivery?.deliveredAt, now: model.currentDate)
            state["machine"] = machine
        }
        return redacting(state, values: heldValues(model)) as? [String: Any] ?? [:]
    }

    @MainActor
    private static func rowState(_ record: CloudSecretRecord, model: CloudSecretsSheetModel) -> [String: Any] {
        let labels = model.machineLabels
        var row: [String: Any] = [:]
        row["name"] = record.name
        row["scope"] = record.scope.wireValue
        row["scope_description"] = CloudSecretsSheetPresentation.scopeDescription(record.scope, machineLabels: labels)
        row["fingerprint_mask"] = CloudSecretsSheetPresentation.maskedFingerprint(record.fingerprint)
        row["updated"] = CloudSecretsSheetPresentation.updatedLabel(record.updatedAt, now: model.currentDate)
        row["source"] = record.source.wireValue
        row["selected"] = model.selectionID == record.sheetID
        row["pill"] = CloudSecretsSheetPresentation.scopePill(record.scope, machineLabels: labels)
        row["state_chip"] = model.rowState(for: record).map { CloudSecretsSheetPresentation.stateTitle($0) }
        // The sheet draws no chip for a current value.
        row["state_chip_visible"] = CloudSecretsSheetPresentation.visibleChip(model.rowState(for: record)) != nil
        return row
    }

    @MainActor
    private static func editorState(_ editor: CloudSecretsSheetModel.Editor, model: CloudSecretsSheetModel) -> [String: Any] {
        var state: [String: Any] = [
            "mode": editor.replacing == nil ? "add" : "replace",
            "name": editor.name,
            // Whether the secure field holds anything; never its contents or length.
            "value_entered": !editor.value.isEmpty,
            "project_text": editor.projectText,
            "is_saving": editor.isSaving,
            "can_save": model.canSaveEditor,
        ]
        state["scope"] = model.editorScope?.wireValue
        state["hint"] = editor.hint
        state["error"] = editor.error
        state["preset"] = model.editorPreset?.name
        return state
    }

    private static func importState(_ draft: CloudSecretsSheetModel.ImportDraft, labels: [String: String]) -> [String: Any] {
        var state: [String: Any] = [
            "source_name": draft.sourceName,
            "scope": draft.scope.wireValue,
            "scope_description": CloudSecretsSheetPresentation.scopeDescription(draft.scope, machineLabels: labels),
            "summary": CloudSecretsSheetPresentation.importSummary(draft.preview),
            "can_commit": draft.preview.canCommit,
            "is_committing": draft.isCommitting,
            "rows": draft.preview.rows.map { row -> [String: Any] in
                var item: [String: Any] = [
                    "name": row.name,
                    // A skipped row's change kind is a placeholder; report what Import does.
                    "kind": row.disposition,
                    "kind_title": CloudSecretsSheetPresentation.importRowTitle(row),
                ]
                item["problem"] = row.problem
                return item
            },
        ]
        state["error"] = draft.error
        return state
    }

    @MainActor
    private static func errors(_ model: CloudSecretsSheetModel) -> [String: Any] {
        var errors: [String: Any] = [:]
        if case .loadFailed(let message) = model.phase { errors["load"] = message }
        errors["action"] = model.actionError
        errors["status"] = model.statusError
        errors["sync"] = model.syncError
        errors["delivery"] = model.delivery?.lastError
        return errors
    }

    /// Values the model still holds: the open editor's field and an import's inputs.
    @MainActor
    static func heldValues(_ model: CloudSecretsSheetModel) -> [String] {
        var values: [String] = []
        if let value = model.editor?.value { values.append(value) }
        if let inputs = model.importDraft?.inputs { values.append(contentsOf: inputs.map(\.value)) }
        return values
    }

    static let redactionMarker = "[redacted]"

    /// Replaces every held value (trimmed, three characters or longer, so a
    /// one-letter value cannot erase labels) inside every string of `object`.
    static func redacting(_ object: Any, values: [String]) -> Any {
        let needles = Set(values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { $0.count >= 3 })
            .sorted { $0.count > $1.count }
        guard !needles.isEmpty else { return object }
        return scrub(object, needles: needles)
    }

    private static func scrub(_ object: Any, needles: [String]) -> Any {
        switch object {
        case let text as String:
            return needles.reduce(text) { $0.replacingOccurrences(of: $1, with: redactionMarker) }
        case let dictionary as [String: Any]:
            return dictionary.mapValues { scrub($0, needles: needles) }
        case let array as [Any]:
            return array.map { scrub($0, needles: needles) }
        default:
            return object
        }
    }
}
#endif
