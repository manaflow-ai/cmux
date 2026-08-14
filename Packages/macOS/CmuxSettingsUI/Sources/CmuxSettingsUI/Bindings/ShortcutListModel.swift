import CmuxFoundation
import CmuxSettings
import Observation
import SwiftUI

/// View-model that owns keyboard shortcut Settings state and persistence.
@MainActor
@Observable
final class ShortcutListModel {

    // MARK: - Observed state

    var bindings: [String: StoredShortcut] = [:]
    var managedBindingActionIDs: Set<String> = []
    var prefix: StoredShortcut = .unbound
    var prefixRejection: ShortcutPrefixPolicyResult?
    var legacyBindings: [String: StoredShortcut]
    private(set) var whenOverrideClauses: [String: ShortcutWhenClause] = [:]
    private(set) var whenOverrideRawStrings: [String: String] = [:]
    var chordModeActions: Set<String> = []
    @ObservationIgnored var chordModeOverrides: [String: Bool] = [:]
    /// The last prefix value written locally, retained until its observation
    /// echo arrives so a stream's initial stale value cannot roll back a
    /// just-recorded leader between sequential Settings edits.
    @ObservationIgnored var pendingPrefix: StoredShortcut?
    private(set) var restoreShortcuts: [String: StoredShortcut] = [:]
    private(set) var bareKeyRejections: Set<String> = []
    private(set) var primaryModifierRejections: Set<String> = []
    private(set) var systemReservedRejections: Set<String> = []
    /// Per-action set marking a numbered action rejected for a non-`1…9` key.
    private(set) var numberedDigitRejections: Set<String> = []
    /// Per-action conflict target for the red validation banner.
    private(set) var conflictRejections: [String: ShortcutAction] = [:]
    @ObservationIgnored private var rejectedConflictShortcuts: [String: StoredShortcut] = [:]
    var pendingBindings: [String: StoredShortcut]?
    @ObservationIgnored var pendingWriteGeneration = 0

    // MARK: - Observation-ignored internals

    @ObservationIgnored let jsonStore: JSONConfigStore
    @ObservationIgnored let userDefaultsStore: UserDefaultsSettingsStore?
    @ObservationIgnored let catalog: SettingCatalog
    @ObservationIgnored let errorLog: SettingsErrorLog
    @ObservationIgnored let onShortcutsChanged: @MainActor () -> Void
    @ObservationIgnored let canRegisterSystemWideHotkey: @MainActor (StoredShortcut) -> Bool
    @ObservationIgnored private let bindingsDriver = SettingReadDriver<ShortcutBindingsSnapshot>()
    @ObservationIgnored private let prefixDriver = SettingReadDriver<StoredShortcut>()
    @ObservationIgnored private let legacyBindingsDriver = SettingReadDriver<[String: StoredShortcut]>()
    @ObservationIgnored private let whenDriver = SettingReadDriver<[String: String]>()

    // MARK: - Init

    /// Creates the model bound to the given stores. Legacy shortcut overrides are
    /// loaded immediately; call ``startObserving()`` to observe both stores.
    init(
        jsonStore: JSONConfigStore,
        userDefaultsStore: UserDefaultsSettingsStore? = nil,
        catalog: SettingCatalog,
        errorLog: SettingsErrorLog,
        canRegisterSystemWideHotkey: @escaping @MainActor (StoredShortcut) -> Bool = {
            ShortcutAction.showHideAllWindows.shortcutBindingPolicyResult(for: $0) == .accepted
        },
        onShortcutsChanged: @escaping @MainActor () -> Void = {}
    ) {
        self.jsonStore = jsonStore
        self.userDefaultsStore = userDefaultsStore
        self.legacyBindings = userDefaultsStore?.initialLegacyShortcutBindings() ?? [:]
        self.catalog = catalog
        self.errorLog = errorLog
        self.canRegisterSystemWideHotkey = canRegisterSystemWideHotkey
        self.onShortcutsChanged = onShortcutsChanged
    }

    // MARK: - Lifecycle

    /// Starts observing the store's shortcut streams. Idempotent: ``SettingReadDriver``
    /// ignores subsequent calls after the first activation.
    func startObserving() {
        let bindingsKey = catalog.shortcuts.bindingSnapshot
        let prefixKey = catalog.shortcuts.prefix
        let whenKey = catalog.shortcuts.when
        bindingsDriver.activate(
            { [jsonStore, bindingsKey] in jsonStore.values(for: bindingsKey) },
            sink: { [weak self] dictionary in self?.ingestBindings(dictionary) }
        )
        prefixDriver.activate(
            { [jsonStore, prefixKey] in jsonStore.values(for: prefixKey) },
            sink: { [weak self] prefix in self?.ingestPrefix(prefix) }
        )
        if let userDefaultsStore {
            legacyBindingsDriver.activate(
                { userDefaultsStore.legacyShortcutBindingValues() },
                sink: { [weak self] dictionary in self?.ingestLegacyBindings(dictionary) }
            )
        }
        whenDriver.activate(
            { [jsonStore, whenKey] in jsonStore.values(for: whenKey) },
            sink: { [weak self] whenMap in
                guard let self else { return }
                self.whenOverrideRawStrings = whenMap
                self.whenOverrideClauses = whenMap.compactMapValues { ShortcutWhenClause.parse($0) }
                self.pruneConflictRejections()
            }
        )
    }

    var latestBindings: [String: StoredShortcut] { pendingBindings ?? bindings }

    private func ingestBindings(_ snapshot: ShortcutBindingsSnapshot) {
        let dictionary = snapshot.bindings
        let changedActionIds = Set(bindings.keys).union(dictionary.keys)
            .filter { bindings[$0] != dictionary[$0] }
        bindings = dictionary
        managedBindingActionIDs = snapshot.managedActionIDs
        pruneRestoreShortcuts()
        pruneConflictRejections(changedActionIds: Set(changedActionIds))
        pruneNumberedDigitRejections(changedActionIds: Set(changedActionIds))
    }

    private func ingestPrefix(_ prefix: StoredShortcut) {
        let normalized = ShortcutPrefixPolicy().normalized(prefix) ?? .unbound
        if let pendingPrefix {
            // The observation stream can yield its initial snapshot before a
            // local write reaches the file watcher. Ignore that stale value;
            // the matching echo (or the post-write read) retires the marker.
            guard normalized == pendingPrefix else { return }
            self.pendingPrefix = nil
        }
        self.prefix = normalized
        prefixRejection = nil
    }

    private func ingestLegacyBindings(_ dictionary: [String: StoredShortcut]) {
        let changedActionIds = Set(legacyBindings.keys).union(dictionary.keys)
            .filter { legacyBindings[$0] != dictionary[$0] }
        legacyBindings = dictionary
        pruneRestoreShortcuts()
        pruneConflictRejections(changedActionIds: Set(changedActionIds))
        pruneNumberedDigitRejections(changedActionIds: Set(changedActionIds))
    }

    // MARK: - Conflict helpers (moved verbatim from section)

    /// The effective focus `when` clause for `action`: its `shortcuts.when`
    /// override, or the built-in ``ShortcutAction/defaultFocusWhenClause``.
    private func effectiveWhenClause(for action: ShortcutAction) -> ShortcutWhenClause {
        whenOverrideClauses[action.rawValue] ?? action.defaultFocusWhenClause
    }

    /// The "When: …" scope caption for `action` — the user's raw override text if
    /// present, otherwise the built-in focus-context description; `nil` when the
    /// shortcut is unrestricted.
    func scopeCaption(for action: ShortcutAction) -> String? {
        if let overrideClause = whenOverrideClauses[action.rawValue] {
            // An explicit empty/`true` override means "no restriction" — show
            // nothing rather than the built-in scope it replaced.
            guard overrideClause != .always else { return nil }
            let raw = whenOverrideRawStrings[action.rawValue]?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !raw.isEmpty else { return nil }
            let format = String(localized: "shortcut.when.caption.override", defaultValue: "When: %@")
            return String.localizedStringWithFormat(format, raw)
        }
        switch action.defaultFocusWhenClause {
        case .always:
            return nil
        case .atom(.sidebarFocus):
            return String(
                localized: "shortcut.when.caption.sidebarFocus",
                defaultValue: "Only while the right sidebar is focused"
            )
        case .atom(.browserFocus):
            return String(
                localized: "shortcut.when.caption.browserFocus",
                defaultValue: "Only while a browser pane is focused"
            )
        case .atom(.filePreviewTextEditorFocus):
            return String(
                localized: "shortcut.when.caption.filePreviewTextEditorFocus",
                defaultValue: "Only while a text file preview is focused"
            )
        case .or(.atom(.browserFocus), .atom(.filePreviewTextEditorFocus)),
             .or(.atom(.filePreviewTextEditorFocus), .atom(.browserFocus)):
            return String(
                localized: "shortcut.when.caption.browserOrFilePreviewTextEditorFocus",
                defaultValue: "Only while a browser pane or text file preview is focused"
            )
        case .atom(.markdownFocus):
            return String(
                localized: "shortcut.when.caption.markdownFocus",
                defaultValue: "Only while a markdown preview is focused"
            )
        case .atom(.simulatorFocus):
            return String(localized: "shortcut.when.caption.simulatorFocus", defaultValue: "Only while a Simulator is focused")
        default:
            return String(
                localized: "shortcut.when.caption.terminalFocus",
                defaultValue: "Only while a terminal pane is focused"
            )
        }
    }

    /// The recorder placeholder text for `effective`: its display glyphs, or the
    /// localized "None" when unbound.
    func formatPlaceholder(effective: StoredShortcut?, numbered: Bool) -> String {
        let unboundLabel = String(localized: "shortcut.unbound.displayValue", defaultValue: "None")
        guard let effective else { return unboundLabel }
        if effective.isUnbound { return unboundLabel }
        return format(effective, numbered: numbered)
    }

    /// Renders `shortcut` to its user-facing display string.
    private func format(_ shortcut: StoredShortcut, numbered: Bool = false) -> String {
        shortcutDisplayString(shortcut, numbered: numbered)
    }

    /// Returns the action `stroke` would collide with under `action`'s effective
    /// `when` clause, or `nil` when there is no conflict. Context-disjoint or
    /// priority-routed clauses coexist, matching the app target's check.
    private func detectConflict(for action: ShortcutAction, stroke: StoredShortcut) -> ShortcutAction? {
        let proposedClause = effectiveWhenClause(for: action)
        for other in ShortcutAction.allCases where other != action {
            guard ShortcutWhenClause.bindingsCollide(
                proposedClause,
                lhsHasPriority: action.hasPriorityShortcutRouting,
                effectiveWhenClause(for: other),
                rhsHasPriority: other.hasPriorityShortcutRouting
            ) else { continue }
            let effective = effective(for: other)
            guard let effective, !effective.isUnbound else { continue }
            if ShortcutBindingConflict(
                proposed: stroke,
                proposedUsesNumberedDigitMatching: action.usesNumberedDigitMatching,
                configured: effective,
                configuredUsesNumberedDigitMatching: other.usesNumberedDigitMatching
            ).exists {
                return other
            }
        }
        return nil
    }

    // MARK: - Mutators (moved verbatim from section)

    /// Dismisses all rejection banners for the action (the Undo button handler).
    func clearRejections(for action: ShortcutAction) {
        bareKeyRejections.remove(action.rawValue)
        primaryModifierRejections.remove(action.rawValue)
        systemReservedRejections.remove(action.rawValue)
        numberedDigitRejections.remove(action.rawValue)
        conflictRejections.removeValue(forKey: action.rawValue)
        rejectedConflictShortcuts.removeValue(forKey: action.rawValue)
    }

    func markBareKeyRejected(_ action: ShortcutAction) {
        clearRejections(for: action)
        bareKeyRejections.insert(action.rawValue)
    }

    private func markPrimaryModifierRejected(_ action: ShortcutAction) {
        clearRejections(for: action)
        primaryModifierRejections.insert(action.rawValue)
    }

    private func markSystemReservedRejected(_ action: ShortcutAction) {
        clearRejections(for: action)
        systemReservedRejections.insert(action.rawValue)
    }

    /// The X/restore button handler: clears rejections then either restores a
    /// previously cached stroke (if the binding is currently unbound) or clears
    /// the binding and caches the current effective stroke for a future restore.
    func clearOrRestore(for action: ShortcutAction) async {
        let eff = effective(for: action)
        let canRestoreAction = canRestore(for: action)
        clearRejections(for: action)
        if canRestoreAction, let restore = restoreShortcuts[action.rawValue] {
            await restoreBinding(restore, for: action)
        } else if let eff, !eff.isUnbound {
            restoreShortcuts[action.rawValue] = eff
            await clearBinding(for: action)
        }
    }

    /// Records a single-stroke shortcut for `action`, rejecting (without writing)
    /// a non-digit stroke on a numbered action or a stroke that conflicts with
    /// another binding; a valid stroke is normalized, persisted, and clears the
    /// action's rejection/restore state.
    func assign(
        stroke: ShortcutStroke,
        to action: ShortcutAction,
        preservingSupportedLegacyBareSpace: Bool = false
    ) async {
        var stroke = stroke.canonicalized()
        let restoresSupportedLegacyBareSpace = preservingSupportedLegacyBareSpace
            && action.shortcutBindingPolicyResult(
                for: StoredShortcut(first: stroke)
            ) == .accepted
        guard action.allowsBareFirstStroke
            || stroke.hasAnyModifier
            || restoresSupportedLegacyBareSpace else {
            markBareKeyRejected(action)
            return
        }
        if action.usesNumberedDigitMatching {
            guard isNumberedDigitKey(stroke.key) else {
                clearRejections(for: action)
                numberedDigitRejections.insert(action.rawValue)
                return
            }
            stroke = ShortcutStroke(
                key: "1",
                command: stroke.command,
                shift: stroke.shift,
                option: stroke.option,
                control: stroke.control,
                keyCode: stroke.keyCode
            )
        }
        let proposed = StoredShortcut(first: stroke)
        switch action.shortcutBindingPolicyResult(for: proposed) {
        case .accepted:
            break
        case .primaryModifierRequired:
            markPrimaryModifierRejected(action)
            return
        case .bareFirstStrokeNotAllowed:
            markBareKeyRejected(action)
            return
        case .chordNotAllowed,
             .systemDefinedMediaKeyNotAllowed,
             .systemReservedShortcutNotAllowed:
            markSystemReservedRejected(action)
            return
        }
        if action == .showHideAllWindows,
           !canRegisterSystemWideHotkey(proposed) {
            markSystemReservedRejected(action)
            return
        }
        if let conflict = detectConflict(for: action, stroke: proposed) {
            // Mirror legacy `KeyboardShortcutSettings.Action.normalizedRecordedShortcutResult`:
            // never write a conflicting binding. Surface the rejection
            // through `conflictRejections` so the banner + Undo button
            // can drive the user back to a usable state.
            clearRejections(for: action)
            conflictRejections[action.rawValue] = conflict
            rejectedConflictShortcuts[action.rawValue] = proposed
            return
        }
        var updated = latestBindings
        updated[action.rawValue] = proposed
        restoreShortcuts.removeValue(forKey: action.rawValue)
        clearChordModeOverride(for: action)
        clearRejections(for: action)
        await write(updated, clearingLegacyFor: action)
    }

    /// Records a two-stroke chord for `action`, rejecting (without writing) an
    /// action that disallows chords, a non-digit numbered chord, or a chord that
    /// conflicts with another binding.
    func assignChord(_ chord: StoredShortcut, to action: ShortcutAction) async {
        var chord = chord.canonicalized()
        // A malformed callback (or an external caller) must never turn into a
        // single-stroke write.  The recorder normally always supplies a
        // suffix, but keeping this guard at the persistence boundary preserves
        // the two-stroke invariant when a view is torn down mid-recording.
        guard let second = chord.second, !second.key.isEmpty else {
            clearChordModeOverride(for: action)
            return
        }

        let normalizedConfiguredPrefix = ShortcutPrefixPolicy().normalized(prefix)
        if let normalizedConfiguredPrefix, !normalizedConfiguredPrefix.isUnbound {
            chord = StoredShortcut(first: normalizedConfiguredPrefix.first, second: second)
        }
        guard let proposed = normalizedNumberedShortcutIfNeeded(chord, for: action) else {
            clearRejections(for: action)
            numberedDigitRejections.insert(action.rawValue)
            clearChordModeOverride(for: action)
            return
        }
        switch action.shortcutBindingPolicyResult(for: proposed) {
        case .accepted:
            break
        case .bareFirstStrokeNotAllowed:
            markBareKeyRejected(action)
            clearChordModeOverride(for: action)
            return
        case .primaryModifierRequired,
             .chordNotAllowed,
             .systemDefinedMediaKeyNotAllowed,
             .systemReservedShortcutNotAllowed:
            markSystemReservedRejected(action)
            clearChordModeOverride(for: action)
            return
        }
        if let conflict = detectConflict(for: action, stroke: proposed) {
            clearRejections(for: action)
            conflictRejections[action.rawValue] = conflict
            rejectedConflictShortcuts[action.rawValue] = proposed
            clearChordModeOverride(for: action)
            return
        }
        var updated = latestBindings
        updated[action.rawValue] = proposed
        clearChordModeOverride(for: action)
        restoreShortcuts.removeValue(forKey: action.rawValue)
        clearRejections(for: action)
        await write(updated, clearingLegacyFor: action)
    }

    /// Persists an unbound binding for `action`.
    func clearBinding(for action: ShortcutAction) async {
        var updated = latestBindings
        updated[action.rawValue] = StoredShortcut.unbound
        clearChordModeOverride(for: action)
        await write(updated, clearingLegacyFor: action)
    }

    /// Restores `shortcut` through the same validation path as a new recording.
    func restoreBinding(_ shortcut: StoredShortcut, for action: ShortcutAction) async {
        if shortcut.hasChord {
            await assignChord(shortcut, to: action)
        } else {
            await assign(
                stroke: shortcut.first,
                to: action,
                preservingSupportedLegacyBareSpace: true
            )
        }
    }

    /// Clears every override and all in-memory rejection/restore state — the
    /// "Reset Defaults" action.
    func resetAll() async {
        restoreShortcuts.removeAll()
        bareKeyRejections.removeAll()
        primaryModifierRejections.removeAll()
        systemReservedRejections.removeAll()
        numberedDigitRejections.removeAll()
        conflictRejections.removeAll()
        rejectedConflictShortcuts.removeAll()
        chordModeActions.removeAll()
        chordModeOverrides.removeAll()
        pendingPrefix = nil
        prefix = .unbound
        prefixRejection = nil
        await write([:], resetAllLegacy: true)
        do {
            try await jsonStore.reset(catalog.shortcuts.prefix)
            onShortcutsChanged()
        } catch {
            prefix = await jsonStore.value(for: catalog.shortcuts.prefix)
            errorLog.record(error, keyID: catalog.shortcuts.prefix.id)
        }
    }

    // MARK: - Prune helpers (moved verbatim from section)

    /// Drops the "Use a digit from 1 through 9" banner for an action only when
    /// *that action's* binding actually changed in the latest stream update.
    func pruneNumberedDigitRejections(changedActionIds: Set<String>) {
        guard !numberedDigitRejections.isEmpty else { return }
        for key in Array(numberedDigitRejections) where changedActionIds.contains(key) {
            numberedDigitRejections.remove(key)
        }
    }

    /// Drops conflict banners for actions whose binding now resolves cleanly
    /// (e.g. after an external cmux.json edit removes the colliding binding).
    func pruneConflictRejections(changedActionIds: Set<String> = []) {
        guard !conflictRejections.isEmpty else { return }
        for key in Array(conflictRejections.keys) {
            guard let action = ShortcutAction(rawValue: key) else {
                conflictRejections.removeValue(forKey: key)
                rejectedConflictShortcuts.removeValue(forKey: key)
                continue
            }
            guard let rejected = rejectedConflictShortcuts[key] else {
                conflictRejections.removeValue(forKey: key)
                continue
            }
            if changedActionIds.contains(key) {
                conflictRejections.removeValue(forKey: key)
                rejectedConflictShortcuts.removeValue(forKey: key)
                continue
            }
            if let conflict = detectConflict(for: action, stroke: rejected) {
                conflictRejections[key] = conflict
            } else {
                conflictRejections.removeValue(forKey: key)
                rejectedConflictShortcuts.removeValue(forKey: key)
            }
        }
    }

    /// Drops cached restore strokes for actions that are no longer unbound.
    func pruneRestoreShortcuts() {
        guard !restoreShortcuts.isEmpty else { return }
        // Iterate a key snapshot because the loop mutates `restoreShortcuts`.
        for key in Array(restoreShortcuts.keys) {
            if let action = ShortcutAction(rawValue: key),
               effective(for: action)?.isUnbound ?? true { continue }
            restoreShortcuts.removeValue(forKey: key)
        }
    }
}
