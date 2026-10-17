#if DEBUG
import CmuxCloud
import Foundation

extension CloudDebugSecretsProbe {
    /// What an action did, before any async work it started finishes.
    enum Outcome: Equatable {
        case applied
        /// The model ignored the action (its own guard, e.g. no editor open).
        case ignored(String)
        case notFound(String)
    }

    /// Async actions the socket started and has not seen finish; `state`
    /// reports `busy` while this is above zero.
    @MainActor static var inFlightActions = 0

    /// Runs one action through the model method the sheet's control calls,
    /// awaiting async ones. The socket verb runs async actions in a task and
    /// reports `busy` until they return; tests await this directly.
    @MainActor
    static func perform(_ action: Action, on model: CloudSecretsSheetModel) async -> Outcome {
        if let outcome = performSync(action, on: model) { return outcome }
        if let refusal = preflight(action, on: model) { return refusal }
        switch action {
        case .save:
            await model.saveEditor()
        case .importText(let text, let sourceName):
            // Paste from the clipboard ends in the same beginImport call.
            let name = sourceName ?? String(localized: "cloudSecrets.import.paste.source", defaultValue: "Clipboard")
            await model.beginImport(text: text, sourceName: name, source: .dotenv(sourceName ?? "clipboard"))
        case .importCommit:
            await model.commitImport()
        case .remove(let name, let scope, _):
            guard let record = record(named: name, scope: scope, in: model) else { return .notFound("no secret named \(name)") }
            // The row's Remove opens the confirmation dialog; its Remove button confirms.
            model.requestRemoval(record)
            await model.confirmRemoval()
        case .syncNow:
            await model.syncNow()
        default:
            break
        }
        return .applied
    }

    /// Why an async action would be refused, checked before the socket starts
    /// it so the reply can say so; nil when it may run.
    @MainActor
    static func preflight(_ action: Action, on model: CloudSecretsSheetModel) -> Outcome? {
        switch action {
        case .save:
            return model.canSaveEditor ? nil : .ignored("the editor cannot save yet")
        case .importCommit:
            guard let draft = model.importDraft, draft.preview.canCommit, !draft.isCommitting else {
                return .ignored("nothing to import")
            }
            return nil
        case .remove(let name, let scope, _):
            // Rows are disabled while the add card or an import preview is open.
            guard !model.hasModalCard else { return .ignored("rows are disabled behind an open card") }
            return record(named: name, scope: scope, in: model) == nil ? .notFound("no secret named \(name)") : nil
        case .syncNow:
            guard model.isMachineMode else { return .ignored("Sync Now needs a sheet opened for a machine") }
            return model.isSyncing ? .ignored("a sync is already running") : nil
        default:
            return nil
        }
    }

    /// Runs a synchronous action; nil for the async ones (``Action/isAsync``).
    @MainActor
    static func performSync(_ action: Action, on model: CloudSecretsSheetModel) -> Outcome? {
        guard !action.isAsync else { return nil }
        switch action {
        case .selectTab(let tab):
            // The scope bar's segmented picker binds `model.tab`.
            model.tab = tab
        case .selectProject(let key):
            model.projectKey = key
        case .openAdd(let presetName):
            guard model.canAdd else { return .ignored("add is unavailable on this tab") }
            // Preset chips and the Add button both call beginAdd(name:).
            model.beginAdd(name: presetName ?? "")
        case .openReplace(let name, let scope):
            guard !model.hasModalCard else { return .ignored("rows are disabled behind an open card") }
            guard let record = record(named: name, scope: scope, in: model) else { return .notFound("no secret named \(name)") }
            model.beginReplace(record)
        case .setEditorName(let name):
            guard model.editor != nil else { return .ignored("no editor is open") }
            model.editor?.name = name
        case .setEditorValue(let value):
            guard model.editor != nil else { return .ignored("no editor is open") }
            // The SecureField binds `editor.value`; the value is never echoed.
            model.editor?.value = value
        case .setEditorProject(let project):
            guard model.editor != nil else { return .ignored("no editor is open") }
            model.editor?.projectText = project
        case .cancel:
            // Esc: the innermost card, then the sheet.
            model.cancel()
        case .importCancel:
            guard model.importDraft != nil else { return .ignored("no import preview is open") }
            model.cancelImport()
        case .remove(let name, let scope, _):
            // Without confirm: the row's Remove, which leaves the dialog up.
            guard !model.hasModalCard else { return .ignored("rows are disabled behind an open card") }
            guard let record = record(named: name, scope: scope, in: model) else { return .notFound("no secret named \(name)") }
            model.requestRemoval(record)
        case .cancelRemove:
            // The dialog's Cancel button.
            guard model.pendingRemoval != nil else { return .ignored("no removal is pending") }
            model.pendingRemoval = nil
        case .selectRow(let name, let scope):
            guard !model.hasModalCard else { return .ignored("rows are disabled behind an open card") }
            guard let record = record(named: name, scope: scope, in: model) else { return .notFound("no secret named \(name)") }
            model.selectionID = record.sheetID
        case .setRequirement(let name):
            guard let requirement = model.unsetRequirements.first(where: { $0.name == name }) else {
                return .notFound("no unset requirement named \(name)")
            }
            model.beginSetRequirement(requirement)
        case .save, .importText, .importCommit, .syncNow:
            return nil
        }
        return .applied
    }
}
#endif
