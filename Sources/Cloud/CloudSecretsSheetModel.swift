import CmuxCloud
import Foundation
import Observation

/// The calls the Cloud Secrets sheet makes. The app binds them to
/// ``CloudSecretsService``; tests bind them to an in-memory vault. Every
/// call carries names, scopes and fingerprints out; values only go in.
struct CloudSecretsSheetBackend {
    struct Snapshot {
        var records: [CloudSecretRecord]
        var deliveries: [CloudSecretDelivery]
    }

    var load: @MainActor () async throws -> Snapshot
    var set: @MainActor ([CloudSecretInput], CloudSecretScope, CloudSecretSource) async throws -> [CloudSecretChange]
    var remove: @MainActor ([String], CloudSecretScope) async throws -> [CloudSecretChange]
    /// The vault's dry run of `set`; nil when the host has none, in which
    /// case the preview falls back to names already in the scope.
    var preview: (@MainActor ([CloudSecretInput], CloudSecretScope) async throws -> [CloudSecretChange])?
    var status: @MainActor (String) async throws -> [CloudSecretMachineStatusRow]
    /// Syncs one machine and returns the redacted error text, nil on success.
    var sync: @MainActor (String) async -> String?
    /// The names a local checkout declares (`.cmux/cloud.json`, devcontainer), read
    /// off the main actor; nil when the host cannot read checkouts.
    var declared: (@MainActor (URL) async -> [CloudSecretRequirement])? = nil
}

/// State behind the Cloud Secrets sheet: the list for the selected scope,
/// the add/replace editor, the `.env` import preview, removal confirmation
/// and, when opened from a machine, that machine's delivery state.
@MainActor
@Observable
final class CloudSecretsSheetModel {
    typealias Tab = CloudSecretsSheetPresentation.Tab

    enum Phase: Equatable {
        case loading
        case ready
        case loadFailed(String)
    }

    /// The inline add/replace card. `value` lives only here while the card is
    /// open and is cleared when it closes.
    struct Editor {
        enum Mode: Equatable {
            case add
            case replace(CloudSecretRecord)
        }

        var mode: Mode
        var name: String
        var value: String = ""
        var projectText: String
        /// Why this name is being added (a repository's description of it), when known.
        var hint: String?
        var error: String?
        var isSaving = false

        var replacing: CloudSecretRecord? {
            if case .replace(let record) = mode { return record }
            return nil
        }
    }

    struct ImportDraft {
        var sourceName: String
        var source: CloudSecretSource
        var scope: CloudSecretScope
        var inputs: [CloudSecretInput]
        var preview: CloudSecretsSheetPresentation.ImportPreview
        var error: String?
        var isCommitting = false
    }

    let machineID: String?
    let machineLabel: String?
    /// The project of the window the sheet opened from, offered first.
    let contextProjectKey: String?
    /// The local checkout the sheet opened from, whose declared names the Project
    /// tab lists when they are not set.
    let contextCheckout: CloudSecretProjectCheckout?
    var machineLabels: [String: String]

    private(set) var phase: Phase = .loading
    private(set) var records: [CloudSecretRecord] = []
    private(set) var deliveries: [CloudSecretDelivery] = []
    private(set) var statusRows: [CloudSecretMachineStatusRow] = []
    /// What ``contextCheckout`` declares, read on each load.
    private(set) var declaredRequirements: [CloudSecretRequirement] = []
    private(set) var statusError: String?
    private(set) var isSyncing = false
    private(set) var syncError: String?
    /// Set after a sync that delivered, so the sheet can say to open a new terminal.
    private(set) var didSync = false

    var tab: Tab = .all {
        didSet { if tab != oldValue { selectionID = nil } }
    }
    /// The Project tab's project; nil lists every project's secrets.
    var projectKey: String?
    var selectionID: String?
    var editor: Editor?
    var importDraft: ImportDraft?
    /// Set by Remove; the sheet confirms before ``confirmRemoval()``.
    var pendingRemoval: CloudSecretRecord?
    private(set) var actionError: String?

    var onFinished: (@MainActor () -> Void)?

    private let backend: CloudSecretsSheetBackend
    private let now: @MainActor () -> Date
    private var isFinished = false

    init(
        machineID: String? = nil,
        machineLabel: String? = nil,
        contextProjectKey: String? = nil,
        contextCheckout: CloudSecretProjectCheckout? = nil,
        machineLabels: [String: String] = [:],
        backend: CloudSecretsSheetBackend,
        now: @escaping @MainActor () -> Date = Date.init
    ) {
        self.machineID = machineID
        self.machineLabel = machineLabel.flatMap { $0.isEmpty ? nil : $0 } ?? machineID
        self.contextProjectKey = contextProjectKey ?? contextCheckout?.projectKey
        self.contextCheckout = contextCheckout
        var labels = machineLabels
        if let machineID, let machineLabel, !machineLabel.isEmpty { labels[machineID] = machineLabel }
        self.machineLabels = labels
        self.backend = backend
        self.now = now
        // Opened from a checkout: the Project tab starts on that project.
        if machineID == nil, let checkout = contextCheckout { projectKey = checkout.projectKey }
    }

    // MARK: Derived

    var isMachineMode: Bool { machineID != nil }
    var currentDate: Date { now() }

    var visibleRecords: [CloudSecretRecord] {
        CloudSecretsSheetPresentation.records(records, tab: tab, projectKey: tab == .project ? projectKey : nil, machineID: machineID)
    }

    func count(for tab: Tab) -> Int {
        CloudSecretsSheetPresentation.records(records, tab: tab, projectKey: nil, machineID: machineID).count
    }

    var projectKeys: [String] {
        CloudSecretsSheetPresentation.projectKeys(records: records, deliveries: deliveries, machineID: machineID, context: contextProjectKey)
    }

    /// The scope Add writes to on the current tab, or nil when the tab has no
    /// single target yet.
    var scopeForNewSecret: CloudSecretScope? {
        CloudSecretsSheetPresentation.scopeForNewSecret(tab: tab, projectKey: projectKey, machineID: machineID)
    }

    /// Adding needs a target: every tab but Machines without a machine. The
    /// Project tab asks for the project inside the editor.
    var canAdd: Bool {
        tab != .machine || machineID != nil
    }

    var isEmptyVault: Bool { phase == .ready && records.isEmpty }

    var selectedRecord: CloudSecretRecord? {
        guard let selectionID else { return nil }
        return visibleRecords.first { $0.sheetID == selectionID }
    }

    /// The first five catalog presets whose name is not yet stored in the
    /// tab's scope.
    var availablePresets: [CloudSecretCatalog.Preset] {
        let scope = scopeForNewSecret
        let stored = Set(records.filter { scope == nil || $0.scope == scope }.map(\.name))
        return CloudSecretCatalog.presets.prefix(5).filter { !stored.contains($0.name) }
    }

    var delivery: CloudSecretDelivery? {
        guard let machineID else { return nil }
        return deliveries.first { $0.machineID == machineID }
    }

    func rowState(for record: CloudSecretRecord) -> CloudSecretsSheetPresentation.RowState? {
        guard isMachineMode else { return nil }
        return CloudSecretsSheetPresentation.rowState(
            for: record,
            statusRows: statusRows,
            linkedProjects: delivery?.projectKeys ?? []
        )
    }

    /// Names the machine still has that no scope holds any more.
    var extraNames: [String] {
        statusRows.filter { $0.state == .extra }.map(\.name).sorted()
    }

    var hasModalCard: Bool { editor != nil || importDraft != nil }

    /// On the Project tab, the names the context checkout declares that nothing
    /// covers for its project (an all-machines secret or one for that project), in
    /// declaration order. Empty on other tabs, or when another project is selected.
    var unsetRequirements: [CloudSecretRequirement] {
        guard tab == .project, let checkout = contextCheckout,
              projectKey == nil || projectKey == checkout.projectKey else { return [] }
        return CloudSecretRequirements.missing(
            declaredRequirements,
            records: records,
            projectKeys: [checkout.projectKey],
            machineID: nil
        )
    }

    /// "owner/repo" for the ghost rows' "Needed by …".
    var unsetRequirementsProjectLabel: String {
        contextCheckout.map { CloudSecretsSheetPresentation.shortProjectLabel($0.projectKey) } ?? ""
    }

    /// Set… on a ghost row: the add card with the name filled in, scoped to the
    /// checkout's project, and the repository's description as its hint.
    func beginSetRequirement(_ requirement: CloudSecretRequirement) {
        guard let checkout = contextCheckout, !hasModalCard else { return }
        tab = .project
        beginAdd(name: requirement.name)
        editor?.projectText = checkout.projectKey
        editor?.hint = CloudSecretsSheetPresentation.requirementHint(requirement, projectLabel: unsetRequirementsProjectLabel)
    }

    // MARK: Loading

    func load() async {
        if phase != .ready { phase = .loading }
        do {
            let snapshot = try await backend.load()
            records = snapshot.records
            deliveries = snapshot.deliveries
            if projectKey == nil, isMachineMode { projectKey = delivery?.projectKeys.first }
            if let checkout = contextCheckout, let declared = backend.declared {
                declaredRequirements = await declared(checkout.root)
            }
            phase = .ready
        } catch {
            phase = .loadFailed(CloudSecretsSheetPresentation.message(for: error))
            return
        }
        await loadStatus()
    }

    func loadStatus() async {
        guard let machineID else { return }
        do {
            statusRows = try await backend.status(machineID)
            statusError = nil
        } catch {
            statusError = CloudSecretsSheetPresentation.message(for: error)
        }
    }

    // MARK: Editor

    /// Opens the add card, optionally with a preset's name filled in.
    func beginAdd(name: String = "") {
        guard canAdd else { return }
        importDraft = nil
        actionError = nil
        editor = Editor(mode: .add, name: name, projectText: projectKey ?? projectKeys.first ?? "")
    }

    func beginReplace(_ record: CloudSecretRecord) {
        importDraft = nil
        actionError = nil
        selectionID = record.sheetID
        editor = Editor(mode: .replace(record), name: record.name, projectText: record.scope.target)
    }

    func cancelEditor() {
        editor = nil
    }

    /// The scope the open editor writes: the replaced record's scope, or the
    /// tab's scope with the project typed in the card.
    var editorScope: CloudSecretScope? {
        guard let editor else { return nil }
        if let record = editor.replacing { return record.scope }
        if tab == .project {
            return CloudSecretsSheetPresentation.normalizedProjectKey(editor.projectText).map { .project($0) }
        }
        return scopeForNewSecret
    }

    var canSaveEditor: Bool {
        guard let editor, !editor.isSaving, editorScope != nil else { return false }
        return !editor.name.trimmingCharacters(in: .whitespaces).isEmpty
            && !editor.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The preset matching the typed name, for the "Get a key" link.
    var editorPreset: CloudSecretCatalog.Preset? {
        guard let name = editor?.name.trimmingCharacters(in: .whitespaces) else { return nil }
        return CloudSecretCatalog.presets.first { $0.name == name }
    }

    func saveEditor() async {
        guard canSaveEditor, var draft = editor, let scope = editorScope else { return }
        let name = draft.name.trimmingCharacters(in: .whitespaces)
        // Pasted keys often carry a trailing newline; a key never has edge whitespace.
        let value = draft.value.trimmingCharacters(in: .whitespacesAndNewlines)
        let input = CloudSecretInput(name: name, value: value)
        do {
            try input.validate()
        } catch {
            draft.error = CloudSecretsSheetPresentation.message(for: error)
            editor = draft
            return
        }
        draft.isSaving = true
        draft.error = nil
        editor = draft
        do {
            _ = try await backend.set([input], scope, .manual)
            editor = nil
            if case .project(let key) = scope { projectKey = key }
            selectionID = CloudSecretRecord.sheetID(name: name, scope: scope)
            await load()
        } catch {
            guard var current = editor else { return }
            current.isSaving = false
            current.error = CloudSecretsSheetPresentation.message(for: error)
            editor = current
        }
    }

    // MARK: Import

    /// Parses `.env` text and shows its preview for the tab's scope. Nothing
    /// is stored until ``commitImport()``.
    func beginImport(text: String, sourceName: String, source: CloudSecretSource) async {
        editor = nil
        actionError = nil
        let scope: CloudSecretScope
        if let tabScope = scopeForNewSecret {
            scope = tabScope
        } else if tab == .project, let key = projectKeys.first {
            scope = .project(key)
        } else {
            actionError = tab == .project
                ? String(localized: "cloudSecrets.import.needsProject", defaultValue: "Add a secret for a project first, then import into it.")
                : String(localized: "cloudSecrets.import.needsMachine", defaultValue: "Open Secrets from a machine’s menu to import secrets for that machine.")
            return
        }
        let inputs: [CloudSecretInput]
        do {
            inputs = try CloudSecretDotenv.parse(text)
        } catch {
            actionError = CloudSecretsSheetPresentation.message(for: error)
            return
        }
        guard !inputs.isEmpty else {
            actionError = String(localized: "cloudSecrets.import.empty", defaultValue: "That file has no KEY=VALUE lines to import.")
            return
        }
        var changes: [CloudSecretChange]?
        if let preview = backend.preview {
            // Only valid entries reach the dry run; invalid ones are listed with their reason.
            let valid = inputs.filter { (try? $0.validate()) != nil }
            if valid.isEmpty {
                changes = []
            } else {
                changes = try? await preview(valid, scope)
            }
        }
        importDraft = ImportDraft(
            sourceName: sourceName,
            source: source,
            scope: scope,
            inputs: inputs,
            preview: CloudSecretsSheetPresentation.importPreview(inputs: inputs, scope: scope, existing: records, changes: changes)
        )
    }

    func cancelImport() {
        importDraft = nil
    }

    func commitImport() async {
        guard var draft = importDraft, draft.preview.canCommit, !draft.isCommitting else { return }
        draft.isCommitting = true
        draft.error = nil
        importDraft = draft
        do {
            _ = try await backend.set(draft.preview.inputsToCommit, draft.scope, draft.source)
            importDraft = nil
            tab = CloudSecretsSheetPresentation.tab(for: draft.scope)
            if case .project(let key) = draft.scope { projectKey = key }
            await load()
        } catch {
            guard var current = importDraft else { return }
            current.isCommitting = false
            current.error = CloudSecretsSheetPresentation.message(for: error)
            importDraft = current
        }
    }

    /// A file or clipboard read failed before parsing.
    func showActionError(_ message: String) {
        actionError = message
    }

    // MARK: Removal

    func requestRemoval(_ record: CloudSecretRecord) {
        selectionID = record.sheetID
        pendingRemoval = record
    }

    /// Delete key: asks to remove the selected row.
    func requestRemovalOfSelection() -> Bool {
        guard !hasModalCard, let record = selectedRecord else { return false }
        requestRemoval(record)
        return true
    }

    func confirmRemoval() async {
        guard let record = pendingRemoval else { return }
        pendingRemoval = nil
        actionError = nil
        do {
            _ = try await backend.remove([record.name], record.scope)
            if selectionID == record.sheetID { selectionID = nil }
            await load()
        } catch {
            actionError = CloudSecretsSheetPresentation.message(for: error)
        }
    }

    // MARK: Machine

    func syncNow() async {
        guard let machineID, !isSyncing else { return }
        isSyncing = true
        syncError = nil
        let error = await backend.sync(machineID)
        isSyncing = false
        syncError = error
        didSync = error == nil
        await load()
    }

    // MARK: Closing

    /// Esc: closes the innermost card first, then the sheet.
    func cancel() {
        if editor != nil {
            editor = nil
        } else if importDraft != nil {
            importDraft = nil
        } else {
            finish()
        }
    }

    func finish() {
        guard !isFinished else { return }
        isFinished = true
        editor = nil
        importDraft = nil
        onFinished?()
    }
}
