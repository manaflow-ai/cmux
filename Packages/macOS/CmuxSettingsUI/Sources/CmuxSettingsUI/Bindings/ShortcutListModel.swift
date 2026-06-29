// Sources/CmuxSettingsUI/Bindings/ShortcutListModel.swift
import CmuxFoundation
import CmuxSettings
import Observation
import SwiftUI

/// `@Observable` view-model that owns all state and mutation logic for the
/// Keyboard Shortcuts settings section, extracted from ``KeyboardShortcutsSection``
/// as the first step in replacing the LazyVStack with a virtualized NSTableView.
///
/// **Lifecycle** matches ``DefaultsValueModel``: call ``startObserving()`` once
/// from the owning view's `.task` (or from tests). The two ``SettingReadDriver``
/// instances cancel their underlying tasks on `deinit`, so no explicit stop is needed.
///
/// **Staged extraction**: `KeyboardShortcutsSection` still holds its own `@State`
/// copies of all these fields. They are removed in Task 6 once the NSTableView
/// representable is wired up.
@MainActor
@Observable
public final class ShortcutListModel {

    // MARK: - Observed state

    public private(set) var bindings: [String: StoredShortcut] = [:]
    /// Parsed `shortcuts.when` overrides keyed by action id. Conflict detection
    /// evaluates each action's effective clause (override, or its built-in
    /// ``ShortcutAction/defaultFocusWhenClause``) so two same-keystroke bindings
    /// only conflict when some focus state activates both.
    public private(set) var whenOverrideClauses: [String: ShortcutWhenClause] = [:]
    /// The raw `shortcuts.when` expressions keyed by action id, kept alongside the
    /// parsed ``whenOverrideClauses`` so rows can render the user's own clause text
    /// verbatim in the scope caption.
    public private(set) var whenOverrideRawStrings: [String: String] = [:]
    public private(set) var chordModeActions: Set<String> = []
    public private(set) var restoreShortcuts: [String: StoredShortcut] = [:]
    public private(set) var bareKeyRejections: Set<String> = []
    /// Per-action set marking a recording rejected because a numbered action was
    /// given a non-`1…9` key.
    public private(set) var numberedDigitRejections: Set<String> = []
    /// Per-action "rejected attempt" snapshot used to drive the red validation
    /// banner. Never written to disk; Undo simply clears this entry.
    public private(set) var conflictRejections: [String: ShortcutAction] = [:]
    /// SwiftUI-diffable trigger the table representable observes to know a row's
    /// measured height may have changed (banner/caption appeared or disappeared).
    public private(set) var heightRevision: Int = 0
    public private(set) var rowsNeedingRemeasure: Set<String> = []

    // MARK: - Observation-ignored internals

    @ObservationIgnored private let jsonStore: JSONConfigStore
    @ObservationIgnored private let catalog: SettingCatalog
    @ObservationIgnored private let errorLog: SettingsErrorLog
    @ObservationIgnored private let bindingsDriver = SettingReadDriver<[String: StoredShortcut]>()
    @ObservationIgnored private let whenDriver = SettingReadDriver<[String: String]>()

    // MARK: - Init

    public init(jsonStore: JSONConfigStore, catalog: SettingCatalog, errorLog: SettingsErrorLog) {
        self.jsonStore = jsonStore
        self.catalog = catalog
        self.errorLog = errorLog
    }

    // MARK: - Lifecycle

    /// Starts observing the store's shortcut streams. Idempotent: ``SettingReadDriver``
    /// ignores subsequent calls after the first activation.
    public func startObserving() {
        let bindingsKey = catalog.shortcuts.bindings
        let whenKey = catalog.shortcuts.when
        bindingsDriver.activate(
            { [jsonStore, bindingsKey] in jsonStore.values(for: bindingsKey) },
            sink: { [weak self] dictionary in self?.ingestBindings(dictionary) }
        )
        whenDriver.activate(
            { [jsonStore, whenKey] in jsonStore.values(for: whenKey) },
            sink: { [weak self] whenMap in
                guard let self else { return }
                let oldClauses = self.whenOverrideClauses
                self.whenOverrideRawStrings = whenMap
                self.whenOverrideClauses = whenMap.compactMapValues { ShortcutWhenClause.parse($0) }
                // Bump remeasure for rows whose scopeCaption visibility changed.
                let allIds = Set(oldClauses.keys).union(self.whenOverrideClauses.keys)
                for id in allIds where oldClauses[id] != self.whenOverrideClauses[id] {
                    self.bumpRemeasure(id)
                }
            }
        )
    }

    // MARK: - Bindings sink

    /// Body of the old `streamBindings` for-await loop, minus the loop itself.
    private func ingestBindings(_ dictionary: [String: StoredShortcut]) {
        let changedActionIds = Set(bindings.keys).union(dictionary.keys)
            .filter { bindings[$0] != dictionary[$0] }
        bindings = dictionary
        pruneRestoreShortcuts()
        pruneConflictRejections()
        pruneNumberedDigitRejections(changedActionIds: Set(changedActionIds))
    }

    // MARK: - Row-height remeasure

    private func bumpRemeasure(_ actionID: String) {
        rowsNeedingRemeasure.insert(actionID)
        heightRevision &+= 1
    }

    public func consumeRemeasure() -> Set<String> {
        defer { rowsNeedingRemeasure.removeAll() }
        return rowsNeedingRemeasure
    }

    // MARK: - Display helpers (lifted from actionRow inline computations)

    public func effective(for action: ShortcutAction) -> StoredShortcut? {
        bindings[action.rawValue] ?? action.defaultShortcut
    }

    public func canRestore(for action: ShortcutAction) -> Bool {
        let eff = effective(for: action)
        let isUnbound = eff?.isUnbound ?? true
        return isUnbound && restoreShortcuts[action.rawValue] != nil
    }

    public func validationMessage(for action: ShortcutAction) -> String? {
        let numberedDigitRejected = numberedDigitRejections.contains(action.rawValue)
        let bareKeyRejected = bareKeyRejections.contains(action.rawValue)
        let conflict = conflictRejections[action.rawValue]
        if numberedDigitRejected {
            return String(
                localized: "shortcut.recorder.error.numberedShortcutRequiresDigit",
                defaultValue: "Use a digit from 1 through 9."
            )
        }
        if bareKeyRejected {
            return String(
                localized: "shortcut.recorder.error.bareKeyNotAllowed",
                defaultValue: "Shortcuts must include ⌘ ⌥ ⌃ or ⇧"
            )
        }
        if let conflict {
            let conflictOverride = bindings[conflict.rawValue]
            let conflictEffective = conflictOverride ?? conflict.defaultShortcut
            let conflictShortcutString = conflictEffective.map {
                format($0, numbered: conflict.usesNumberedDigitMatching)
            } ?? ""
            let messageFormat = String(
                localized: "shortcut.recorder.error.conflictsWithAction",
                defaultValue: "This shortcut conflicts with %@ (%@)."
            )
            return String.localizedStringWithFormat(messageFormat, conflict.displayName, conflictShortcutString)
        }
        return nil
    }

    // MARK: - Conflict helpers (moved verbatim from section)

    private func effectiveWhenClause(for action: ShortcutAction) -> ShortcutWhenClause {
        whenOverrideClauses[action.rawValue] ?? action.defaultFocusWhenClause
    }

    public func scopeCaption(for action: ShortcutAction) -> String? {
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
        case .atom(.markdownFocus):
            return String(
                localized: "shortcut.when.caption.markdownFocus",
                defaultValue: "Only while a markdown preview is focused"
            )
        default:
            return String(
                localized: "shortcut.when.caption.terminalFocus",
                defaultValue: "Only while a terminal pane is focused"
            )
        }
    }

    public func formatPlaceholder(effective: StoredShortcut?, numbered: Bool) -> String {
        let unboundLabel = String(localized: "shortcut.unbound.displayValue", defaultValue: "None")
        guard let effective else { return unboundLabel }
        if effective.isUnbound { return unboundLabel }
        return format(effective, numbered: numbered)
    }

    private func format(_ shortcut: StoredShortcut, numbered: Bool = false) -> String {
        shortcutDisplayString(shortcut, numbered: numbered)
    }

    private func detectConflict(for action: ShortcutAction, stroke: StoredShortcut) -> ShortcutAction? {
        let proposedClause = effectiveWhenClause(for: action)
        for other in ShortcutAction.allCases where other != action {
            // Two bindings on the same keystroke only collide when some focus
            // state activates both effective `when` clauses AND router priority
            // cannot decide the overlap. Context-disjoint clauses coexist.
            // outright so the factory Select Surface ⌃1…9 coexists with the
            // sidebar's ⌃1…5 — matching the app target's authoritative check.
            guard ShortcutWhenClause.bindingsCollide(
                proposedClause,
                lhsHasPriority: action.hasPriorityShortcutRouting,
                effectiveWhenClause(for: other),
                rhsHasPriority: other.hasPriorityShortcutRouting
            ) else { continue }
            let override = bindings[other.rawValue]
            let effective = override ?? other.defaultShortcut
            guard let effective, !effective.isUnbound else { continue }
            if numberedAwareStrokesConflict(
                stroke.first,
                numbered: action.usesNumberedDigitMatching,
                effective.first,
                numbered: other.usesNumberedDigitMatching
            ) {
                return other
            }
        }
        return nil
    }

    // MARK: - Mutators (moved verbatim from section, bumpRemeasure added on banner-toggling writes)

    /// Dismisses all rejection banners for the action (the Undo button handler).
    public func clearRejections(for action: ShortcutAction) {
        bareKeyRejections.remove(action.rawValue)
        numberedDigitRejections.remove(action.rawValue)
        conflictRejections.removeValue(forKey: action.rawValue)
        bumpRemeasure(action.rawValue)
    }

    /// Records a bare-key rejection for the given action and bumps the remeasure
    /// counter so the hosting NSTableView can invalidate the row's height.
    /// Called by ``ShortcutListRowView``'s `onBareKeyRejected` callback.
    public func markBareKeyRejected(_ action: ShortcutAction) {
        bareKeyRejections.insert(action.rawValue)
        bumpRemeasure(action.rawValue)
    }

    /// The X/restore button handler: clears rejections then either restores a
    /// previously cached stroke (if the binding is currently unbound) or clears
    /// the binding and caches the current effective stroke for a future restore.
    public func clearOrRestore(for action: ShortcutAction) {
        let eff = effective(for: action)
        let canRestoreAction = canRestore(for: action)
        bareKeyRejections.remove(action.rawValue)
        numberedDigitRejections.remove(action.rawValue)
        conflictRejections.removeValue(forKey: action.rawValue)
        bumpRemeasure(action.rawValue)
        if canRestoreAction, let restore = restoreShortcuts[action.rawValue] {
            Task { await self.restoreBinding(restore, for: action) }
        } else if let eff, !eff.isUnbound {
            restoreShortcuts[action.rawValue] = eff
            Task { await self.clearBinding(for: action) }
        }
    }

    public func assign(stroke: ShortcutStroke, to action: ShortcutAction) async {
        var stroke = stroke
        if action.usesNumberedDigitMatching {
            // Numbered actions stand in for the whole 1…9 family. Mirror
            // legacy `resolvedNumberedDigitShortcut`: require a 1…9 digit and
            // normalize it to the "1" placeholder, so we never write a binding
            // the app-target parser rejects (which would also make the Settings
            // row falsely render an active ⌃1…9 range).
            guard isNumberedDigitKey(stroke.key) else {
                numberedDigitRejections.insert(action.rawValue)
                bumpRemeasure(action.rawValue)
                bareKeyRejections.remove(action.rawValue)
                conflictRejections.removeValue(forKey: action.rawValue)
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
        if let conflict = detectConflict(for: action, stroke: proposed) {
            // Mirror legacy `KeyboardShortcutSettings.Action.normalizedRecordedShortcutResult`:
            // never write a conflicting binding. Surface the rejection
            // through `conflictRejections` so the banner + Undo button
            // can drive the user back to a usable state.
            conflictRejections[action.rawValue] = conflict
            bumpRemeasure(action.rawValue)
            bareKeyRejections.remove(action.rawValue)
            numberedDigitRejections.remove(action.rawValue)
            return
        }
        var updated = bindings
        updated[action.rawValue] = proposed
        restoreShortcuts.removeValue(forKey: action.rawValue)
        bareKeyRejections.remove(action.rawValue)
        numberedDigitRejections.remove(action.rawValue)
        conflictRejections.removeValue(forKey: action.rawValue)
        bumpRemeasure(action.rawValue)
        await write(updated)
    }

    public func assignChord(_ chord: StoredShortcut, to action: ShortcutAction) async {
        guard action.allowsChordShortcut else {
            chordModeActions.remove(action.rawValue)
            return
        }
        guard let proposed = normalizedNumberedShortcutIfNeeded(chord, for: action) else {
            numberedDigitRejections.insert(action.rawValue)
            bumpRemeasure(action.rawValue)
            chordModeActions.remove(action.rawValue)
            bareKeyRejections.remove(action.rawValue)
            conflictRejections.removeValue(forKey: action.rawValue)
            return
        }
        if let conflict = detectConflict(for: action, stroke: proposed) {
            conflictRejections[action.rawValue] = conflict
            bumpRemeasure(action.rawValue)
            chordModeActions.remove(action.rawValue)
            bareKeyRejections.remove(action.rawValue)
            numberedDigitRejections.remove(action.rawValue)
            return
        }
        var updated = bindings
        updated[action.rawValue] = proposed
        chordModeActions.remove(action.rawValue)
        restoreShortcuts.removeValue(forKey: action.rawValue)
        bareKeyRejections.remove(action.rawValue)
        numberedDigitRejections.remove(action.rawValue)
        conflictRejections.removeValue(forKey: action.rawValue)
        bumpRemeasure(action.rawValue)
        await write(updated)
    }

    private func normalizedNumberedShortcutIfNeeded(
        _ shortcut: StoredShortcut,
        for action: ShortcutAction
    ) -> StoredShortcut? {
        guard action.usesNumberedDigitMatching else {
            return shortcut
        }
        let digitStroke = shortcut.second ?? shortcut.first
        guard isNumberedDigitKey(digitStroke.key) else {
            return nil
        }
        if let second = shortcut.second {
            return StoredShortcut(
                first: shortcut.first,
                second: ShortcutStroke(
                    key: "1",
                    command: second.command,
                    shift: second.shift,
                    option: second.option,
                    control: second.control,
                    keyCode: second.keyCode
                )
            )
        }
        return StoredShortcut(
            first: ShortcutStroke(
                key: "1",
                command: shortcut.first.command,
                shift: shortcut.first.shift,
                option: shortcut.first.option,
                control: shortcut.first.control,
                keyCode: shortcut.first.keyCode
            )
        )
    }

    func clearBinding(for action: ShortcutAction) async {
        var updated = bindings
        updated[action.rawValue] = StoredShortcut.unbound
        await write(updated)
    }

    func restoreBinding(_ shortcut: StoredShortcut, for action: ShortcutAction) async {
        var updated = bindings
        updated[action.rawValue] = shortcut
        restoreShortcuts.removeValue(forKey: action.rawValue)
        bareKeyRejections.remove(action.rawValue)
        numberedDigitRejections.remove(action.rawValue)
        conflictRejections.removeValue(forKey: action.rawValue)
        bumpRemeasure(action.rawValue)
        await write(updated)
    }

    func resetToDefault(action: ShortcutAction) async {
        var updated = bindings
        updated.removeValue(forKey: action.rawValue)
        restoreShortcuts.removeValue(forKey: action.rawValue)
        bareKeyRejections.remove(action.rawValue)
        numberedDigitRejections.remove(action.rawValue)
        conflictRejections.removeValue(forKey: action.rawValue)
        bumpRemeasure(action.rawValue)
        await write(updated)
    }

    public func resetAll() async {
        for key in bareKeyRejections { bumpRemeasure(key) }
        for key in numberedDigitRejections { bumpRemeasure(key) }
        for key in conflictRejections.keys { bumpRemeasure(key) }
        restoreShortcuts.removeAll()
        bareKeyRejections.removeAll()
        numberedDigitRejections.removeAll()
        conflictRejections.removeAll()
        await write([:])
    }

    private func write(_ updated: [String: StoredShortcut]) async {
        do {
            try await jsonStore.set(updated, for: catalog.shortcuts.bindings)
        } catch {
            errorLog.record(error, keyID: catalog.shortcuts.bindings.id)
        }
    }

    // MARK: - Prune helpers (moved verbatim from section)

    /// Drops the "Use a digit from 1 through 9" banner for an action only when
    /// *that action's* binding actually changed in the latest stream update.
    private func pruneNumberedDigitRejections(changedActionIds: Set<String>) {
        guard !numberedDigitRejections.isEmpty else { return }
        for key in Array(numberedDigitRejections) where changedActionIds.contains(key) {
            numberedDigitRejections.remove(key)
            bumpRemeasure(key)
        }
    }

    private func pruneConflictRejections() {
        guard !conflictRejections.isEmpty else { return }
        // Drop banners for actions whose binding now resolves cleanly.
        // Legacy `ShortcutRecorderSettingsControl` clears `rejectedAttempt`
        // on `.onChange(of: shortcut)`, so an externally-edited binding
        // (cmux.json reload) dismisses the validation banner too.
        for key in Array(conflictRejections.keys) {
            guard let action = ShortcutAction(rawValue: key) else {
                conflictRejections.removeValue(forKey: key)
                bumpRemeasure(key)
                continue
            }
            let effective = bindings[action.rawValue] ?? action.defaultShortcut
            if let effective, detectConflict(for: action, stroke: effective) == nil {
                conflictRejections.removeValue(forKey: key)
                bumpRemeasure(key)
            } else if effective == nil {
                conflictRejections.removeValue(forKey: key)
                bumpRemeasure(key)
            }
        }
    }

    private func pruneRestoreShortcuts() {
        guard !restoreShortcuts.isEmpty else { return }
        for (key, _) in restoreShortcuts {
            let override = bindings[key]
            // If there is no override at all, the action is back to its
            // default stroke (also non-unbound for most actions), so the
            // restore cache is no longer meaningful.
            if let override, override.isUnbound { continue }
            restoreShortcuts.removeValue(forKey: key)
        }
    }
}
