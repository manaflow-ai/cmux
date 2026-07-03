// Sources/CmuxSettingsUI/Bindings/ShortcutListModel.swift
import CmuxFoundation
import CmuxSettings
import Observation
import SwiftUI

/// `@Observable` view-model that owns all state and mutation logic for the
/// Keyboard Shortcuts settings section.
///
/// **Lifecycle** matches ``DefaultsValueModel``: call ``startObserving()`` once
/// from the owning view's `.task` (or from tests). The two ``SettingReadDriver``
/// instances cancel their underlying tasks on `deinit`, so no explicit stop is needed.
///
/// **Threading**: all reads and writes must happen on `@MainActor`; the two
/// ``SettingReadDriver`` sinks are delivered on the main actor automatically.
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
    @ObservationIgnored private var rejectedConflictShortcuts: [String: StoredShortcut] = [:]

    // MARK: - Observation-ignored internals

    @ObservationIgnored private let jsonStore: JSONConfigStore
    @ObservationIgnored private let catalog: SettingCatalog
    @ObservationIgnored private let errorLog: SettingsErrorLog
    @ObservationIgnored private let bindingsDriver = SettingReadDriver<[String: StoredShortcut]>()
    @ObservationIgnored private let whenDriver = SettingReadDriver<[String: String]>()

    // MARK: - Init

    /// Creates the model bound to the given stores. Call ``startObserving()``
    /// before reading state so the bindings and `when` overrides are populated.
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
                self.whenOverrideRawStrings = whenMap
                self.whenOverrideClauses = whenMap.compactMapValues { ShortcutWhenClause.parse($0) }
                self.pruneConflictRejections()
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

    // MARK: - Display helpers (lifted from actionRow inline computations)

    /// The effective shortcut for `action`: its override binding if set,
    /// otherwise the action's built-in default.
    public func effective(for action: ShortcutAction) -> StoredShortcut? {
        bindings[action.rawValue] ?? action.defaultShortcut
    }

    /// Whether `action` is currently unbound but has a cached stroke available to
    /// restore (drives the X → restore button swap).
    public func canRestore(for action: ShortcutAction) -> Bool {
        let eff = effective(for: action)
        let isUnbound = eff?.isUnbound ?? true
        return isUnbound && restoreShortcuts[action.rawValue] != nil
    }

    /// The red validation-banner text for `action` (bare-key, numbered-digit, or
    /// conflict rejection), or `nil` when the row has no pending rejection.
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

    /// The effective focus `when` clause for `action`: its `shortcuts.when`
    /// override, or the built-in ``ShortcutAction/defaultFocusWhenClause``.
    private func effectiveWhenClause(for action: ShortcutAction) -> ShortcutWhenClause {
        whenOverrideClauses[action.rawValue] ?? action.defaultFocusWhenClause
    }

    /// The "When: …" scope caption for `action` — the user's raw override text if
    /// present, otherwise the built-in focus-context description; `nil` when the
    /// shortcut is unrestricted.
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
        default:
            return String(
                localized: "shortcut.when.caption.terminalFocus",
                defaultValue: "Only while a terminal pane is focused"
            )
        }
    }

    /// The recorder placeholder text for `effective`: its display glyphs, or the
    /// localized "None" when unbound.
    public func formatPlaceholder(effective: StoredShortcut?, numbered: Bool) -> String {
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
            // Two bindings on the same keystroke only collide when some focus
            // state activates both effective `when` clauses AND router priority
            // cannot decide the overlap. Context-disjoint clauses (or ones a
            // priority router separates) coexist outright — so the factory
            // Select Surface ⌃1…9 coexists with the sidebar's ⌃1…5 — matching
            // the app target's authoritative check.
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

    // MARK: - Mutators (moved verbatim from section)

    /// Dismisses all rejection banners for the action (the Undo button handler).
    public func clearRejections(for action: ShortcutAction) {
        bareKeyRejections.remove(action.rawValue)
        numberedDigitRejections.remove(action.rawValue)
        conflictRejections.removeValue(forKey: action.rawValue)
        rejectedConflictShortcuts.removeValue(forKey: action.rawValue)
    }

    /// Records a bare-key rejection for the given action. Called by
    /// ``ShortcutListRowView``'s `onBareKeyRejected` callback.
    public func markBareKeyRejected(_ action: ShortcutAction) {
        bareKeyRejections.insert(action.rawValue)
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
        rejectedConflictShortcuts.removeValue(forKey: action.rawValue)
        if canRestoreAction, let restore = restoreShortcuts[action.rawValue] {
            Task { await self.restoreBinding(restore, for: action) }
        } else if let eff, !eff.isUnbound {
            restoreShortcuts[action.rawValue] = eff
            Task { await self.clearBinding(for: action) }
        }
    }

    /// Records a single-stroke shortcut for `action`, rejecting (without writing)
    /// a non-digit stroke on a numbered action or a stroke that conflicts with
    /// another binding; a valid stroke is normalized, persisted, and clears the
    /// action's rejection/restore state.
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
                bareKeyRejections.remove(action.rawValue)
                conflictRejections.removeValue(forKey: action.rawValue)
                rejectedConflictShortcuts.removeValue(forKey: action.rawValue)
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
            rejectedConflictShortcuts[action.rawValue] = proposed
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
        rejectedConflictShortcuts.removeValue(forKey: action.rawValue)
        await write(updated)
    }

    /// Records a two-stroke chord for `action`, rejecting (without writing) an
    /// action that disallows chords, a non-digit numbered chord, or a chord that
    /// conflicts with another binding.
    public func assignChord(_ chord: StoredShortcut, to action: ShortcutAction) async {
        guard action.allowsChordShortcut else {
            chordModeActions.remove(action.rawValue)
            return
        }
        guard let proposed = normalizedNumberedShortcutIfNeeded(chord, for: action) else {
            numberedDigitRejections.insert(action.rawValue)
            chordModeActions.remove(action.rawValue)
            bareKeyRejections.remove(action.rawValue)
            conflictRejections.removeValue(forKey: action.rawValue)
            rejectedConflictShortcuts.removeValue(forKey: action.rawValue)
            return
        }
        if let conflict = detectConflict(for: action, stroke: proposed) {
            conflictRejections[action.rawValue] = conflict
            rejectedConflictShortcuts[action.rawValue] = proposed
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
        rejectedConflictShortcuts.removeValue(forKey: action.rawValue)
        await write(updated)
    }

    /// For a numbered action, normalizes the digit stroke to the "1" placeholder;
    /// returns `nil` if it is not a 1…9 digit. Non-numbered actions pass through
    /// unchanged.
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

    /// Persists an unbound binding for `action`.
    func clearBinding(for action: ShortcutAction) async {
        var updated = bindings
        updated[action.rawValue] = StoredShortcut.unbound
        await write(updated)
    }

    /// Persists `shortcut` for `action` and clears its rejection/restore state.
    func restoreBinding(_ shortcut: StoredShortcut, for action: ShortcutAction) async {
        var updated = bindings
        updated[action.rawValue] = shortcut
        restoreShortcuts.removeValue(forKey: action.rawValue)
        bareKeyRejections.remove(action.rawValue)
        numberedDigitRejections.remove(action.rawValue)
        conflictRejections.removeValue(forKey: action.rawValue)
        rejectedConflictShortcuts.removeValue(forKey: action.rawValue)
        await write(updated)
    }

    /// Clears every override and all in-memory rejection/restore state — the
    /// "Reset Defaults" action.
    public func resetAll() async {
        restoreShortcuts.removeAll()
        bareKeyRejections.removeAll()
        numberedDigitRejections.removeAll()
        conflictRejections.removeAll()
        rejectedConflictShortcuts.removeAll()
        await write([:])
    }

    /// Persists `updated` to the bindings store, recording any failure to the
    /// error log.
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
        }
    }

    /// Drops conflict banners for actions whose binding now resolves cleanly
    /// (e.g. after an external cmux.json edit removes the colliding binding).
    private func pruneConflictRejections() {
        guard !conflictRejections.isEmpty else { return }
        // Drop banners for actions whose binding now resolves cleanly.
        // Legacy `ShortcutRecorderSettingsControl` clears `rejectedAttempt`
        // on `.onChange(of: shortcut)`, so an externally-edited binding
        // (cmux.json reload) dismisses the validation banner too.
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
            if detectConflict(for: action, stroke: rejected) == nil {
                conflictRejections.removeValue(forKey: key)
                rejectedConflictShortcuts.removeValue(forKey: key)
            }
        }
    }

    /// Drops cached restore strokes for actions that are no longer unbound.
    private func pruneRestoreShortcuts() {
        guard !restoreShortcuts.isEmpty else { return }
        // Iterate a key snapshot — the loop mutates `restoreShortcuts`, and
        // mutating a dictionary mid-iteration is undefined (see sibling prunes).
        for key in Array(restoreShortcuts.keys) {
            let override = bindings[key]
            // If there is no override at all, the action is back to its
            // default stroke (also non-unbound for most actions), so the
            // restore cache is no longer meaningful.
            if let override, override.isUnbound { continue }
            restoreShortcuts.removeValue(forKey: key)
        }
    }
}
