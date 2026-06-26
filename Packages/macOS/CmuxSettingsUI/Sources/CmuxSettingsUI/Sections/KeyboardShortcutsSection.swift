import CmuxFoundation
import CmuxSettings
import SwiftUI

/// **Keyboard Shortcuts** section — mirrors the legacy in-app
/// section: one `SettingsCard` containing the chord docs link,
/// the Reset Defaults action, and a per-action recorder row for
/// every `ShortcutAction` (using the new package recorder).
@MainActor
public struct KeyboardShortcutsSection: View {
    private let jsonStore: JSONConfigStore
    private let catalog: SettingCatalog
    private let errorLog: SettingsErrorLog
    private let hostActions: SettingsHostActions
    @State private var bindings: [String: StoredShortcut] = [:]
    /// Parsed `shortcuts.when` overrides keyed by action id. Conflict detection
    /// evaluates each action's effective clause (override, or its built-in
    /// ``ShortcutAction/defaultFocusWhenClause``) so two same-keystroke bindings
    /// only conflict when some focus state activates both — matching the app
    /// target's authoritative check.
    @State private var whenOverrideClauses: [String: ShortcutWhenClause] = [:]
    /// The raw `shortcuts.when` expressions keyed by action id, kept alongside
    /// the parsed ``whenOverrideClauses`` so rows can render the user's own
    /// clause text verbatim in the scope caption.
    @State private var whenOverrideRawStrings: [String: String] = [:]
    @State private var streamTask: Task<Void, Never>?
    @State private var chordModeActions: Set<String> = []
    @State private var restoreShortcuts: [String: StoredShortcut] = [:]
    @State private var bareKeyRejections: Set<String> = []
    /// Per-action set marking a recording rejected because a numbered
    /// action (``ShortcutAction/usesNumberedDigitMatching``) was given a
    /// non-`1…9` key. Mirrors legacy `.numberedShortcutRequiresDigit`: the
    /// binding is never written and a banner prompts for a digit.
    @State private var numberedDigitRejections: Set<String> = []
    /// Per-action "rejected attempt" snapshot used to drive the red
    /// validation banner. Legacy `ShortcutRecorderSettingsControl`
    /// stores `rejectedAttempt` and never writes the conflicting
    /// shortcut; the package previously wrote first then detected the
    /// conflict at render time, which meant the conflict actually
    /// persisted on disk and the Undo button could not roll it back.
    /// This state captures the conflicting action so the banner can
    /// render without persisting the bad binding.
    @State private var conflictRejections: [String: ShortcutAction] = [:]
    public init(
        jsonStore: JSONConfigStore,
        catalog: SettingCatalog,
        errorLog: SettingsErrorLog,
        hostActions: SettingsHostActions
    ) {
        self.jsonStore = jsonStore
        self.catalog = catalog
        self.errorLog = errorLog
        self.hostActions = hostActions
    }

    public var body: some View {
        Group {
            SettingsSectionHeader(String(localized: "settings.section.keyboardShortcuts", defaultValue: "Keyboard Shortcuts"), section: .keyboardShortcuts)
                .accessibilityIdentifier("SettingsKeyboardShortcutsSection")
            SettingsCard {
                chordsRow
                SettingsCardDivider()
                ModifierHoldHintsSettingsRow()
                SettingsCardDivider()
                resetDefaultsRow
                SettingsCardDivider()
                // Filter out actions that live in their own section, then
                // use the shared Settings ordering for sidebar/find actions.
                // ~166 recorder rows, each AppKit-backed — the one heavy
                // list in Settings. The detail stack is eager (so every
                // search anchor stays scroll-addressable), which would
                // otherwise build all of these on window open and cost
                // ~2s. These per-shortcut rows aren't search anchors (only
                // the enclosing card is), so a LazyVStack here defers them
                // until the section scrolls into view without affecting any
                // scroll/highlight target.
                let actions = ShortcutAction.settingsVisibleActions
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(actions.enumerated()), id: \.element) { index, action in
                        actionRow(action)
                        if index < actions.count - 1 {
                            SettingsCardDivider()
                        }
                    }
                }
            }
            .settingsSearchAnchors(["setting:keyboardShortcuts:shortcuts"])
            Text(String(localized: "settings.shortcuts.recordHint", defaultValue: "Click a shortcut value to record. Use X to unbind; it changes to restore after a clear."))
                .cmuxFont(.caption)
                .foregroundColor(.secondary)
                .padding(.leading, 2)
                .accessibilityIdentifier("ShortcutRecordingHint")
        }
        .task { await streamBindings() }
        .task { await streamWhenOverrides() }
        .onDisappear { streamTask?.cancel() }
    }

    @ViewBuilder
    private var chordsRow: some View {
        SettingsCardRow(
            configurationReview: .action,
            searchAnchorID: "setting:keyboardShortcuts:shortcut-chords",
            String(localized: "settings.shortcuts.chords", defaultValue: "Shortcut Chords"),
            subtitle: String(localized: "settings.shortcuts.chords.subtitle", defaultValue: "Add tmux-style multi-step shortcuts in cmux.json, for example [\"ctrl+b\", \"c\"].")
        ) {
            HStack(spacing: 8) {
                Link(
                    String(localized: "settings.shortcuts.chords.docsButton", defaultValue: "Chord docs"),
                    destination: URL(string: "https://cmux.com/docs/keyboard-shortcuts#shortcut-chords")!
                )
                .cmuxFont(.caption)
                .accessibilityIdentifier("SettingsKeyboardShortcutsChordDocsLink")

                Button(String(localized: "settings.app.settingsFile.openButton", defaultValue: "Open cmux.json")) {
                    hostActions.openConfigInExternalEditor()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("SettingsKeyboardShortcutsOpenSettingsFileButton")
            }
        }
    }

    @ViewBuilder
    private var resetDefaultsRow: some View {
        SettingsCardRow(
            configurationReview: .settingsOnly,
            searchAnchorID: "setting:keyboardShortcuts:reset-defaults",
            String(localized: "settings.shortcuts.resetDefaults", defaultValue: "Reset Default Shortcuts"),
            subtitle: String(localized: "settings.shortcuts.resetDefaults.subtitle", defaultValue: "Restore built-in shortcut values for shortcuts managed in app settings.")
        ) {
            Button {
                Task { await resetAll() }
            } label: {
                Label(
                    String(localized: "settings.shortcuts.resetDefaults.button", defaultValue: "Reset Defaults"),
                    systemImage: "arrow.counterclockwise"
                )
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityIdentifier("SettingsKeyboardShortcutsResetDefaultsButton")
        }
    }

    @ViewBuilder
    private func actionRow(_ action: ShortcutAction) -> some View {
        let override = bindings[action.rawValue]
        let effective = override ?? action.defaultShortcut
        let isUnbound = effective?.isUnbound ?? true
        let canRestore = isUnbound && restoreShortcuts[action.rawValue] != nil
        let bareKeyRejected = bareKeyRejections.contains(action.rawValue)
        let numberedDigitRejected = numberedDigitRejections.contains(action.rawValue)
        // Drive the validation banner off the explicit rejection state,
        // not off live bindings. Legacy never persists a conflicting
        // shortcut: `ShortcutRecorderSettingsControl` captures the
        // rejected attempt and shows the banner without ever writing
        // the bad value, so Undo simply clears `rejectedAttempt`.
        let conflict = conflictRejections[action.rawValue]
        let validationMessage: String? = {
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
                // Mirror legacy `ShortcutRecorderValidationPresentation.message`
                // wording: include both the conflicting action label AND its
                // displayed shortcut string in parentheses so the user can
                // identify which existing shortcut is in the way.
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
        }()

        let subtitle: String? = scopeCaption(for: action)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: subtitle == nil ? .center : .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(action.displayName)
                    if let subtitle {
                        Text(subtitle)
                            .cmuxFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                ShortcutRecorderView(
                    placeholder: formatPlaceholder(
                        effective: effective,
                        numbered: action.usesNumberedDigitMatching
                    ),
                    chordsEnabled: chordModeActions.contains(action.rawValue),
                    hasPendingRejection: bareKeyRejected || numberedDigitRejected,
                    firstStrokeRequiresModifier: !action.allowsBareFirstStroke,
                    onStroke: { stroke in Task { await assign(stroke: stroke, to: action) } },
                    onChord: { chord in Task { await assignChord(chord, to: action) } },
                    onBareKeyRejected: { bareKeyRejections.insert(action.rawValue) }
                )
                .frame(width: 160)

                Button {
                    bareKeyRejections.remove(action.rawValue)
                    numberedDigitRejections.remove(action.rawValue)
                    conflictRejections.removeValue(forKey: action.rawValue)
                    if canRestore, let restore = restoreShortcuts[action.rawValue] {
                        Task { await restoreBinding(restore, for: action) }
                    } else if let effective, !effective.isUnbound {
                        restoreShortcuts[action.rawValue] = effective
                        Task { await clearBinding(for: action) }
                    }
                } label: {
                    Image(systemName: canRestore ? "arrow.counterclockwise.circle.fill" : "xmark.circle.fill")
                        .imageScale(.medium)
                }
                .buttonStyle(.borderless)
                .disabled(isUnbound && !canRestore)
                .help(
                    canRestore
                        ? String(localized: "shortcut.recorder.restore.help", defaultValue: "Restore previous shortcut")
                        : String(localized: "shortcut.recorder.clear.help", defaultValue: "Unbind shortcut")
                )
                .accessibilityLabel(
                    canRestore
                        ? String(localized: "shortcut.recorder.restore", defaultValue: "Restore")
                        : String(localized: "shortcut.recorder.clear", defaultValue: "Unbind")
                )
                .accessibilityIdentifier("ShortcutRecorderClearRestoreButton")
            }

            if let validationMessage {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .cmuxFont(.caption)
                        .foregroundStyle(.red)

                    Text(validationMessage)
                        .cmuxFont(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)

                    // Legacy `KeyboardShortcutRecorder` always renders an
                    // Undo button when `onUndoButtonPressed` is set, which
                    // `ShortcutRecorderSettingsControl` wires up for every
                    // rejected attempt (both bare-key and conflict). Match
                    // that so users can dismiss the conflict banner without
                    // having to record a different shortcut.
                    Button(String(localized: "shortcut.recorder.undo", defaultValue: "Undo")) {
                        bareKeyRejections.remove(action.rawValue)
                        numberedDigitRejections.remove(action.rawValue)
                        conflictRejections.removeValue(forKey: action.rawValue)
                    }
                    .buttonStyle(.link)
                    .cmuxFont(.caption)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.red.opacity(0.12))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.red.opacity(0.35), lineWidth: 1)
                }
                .accessibilityIdentifier("ShortcutRecorderValidationMessage")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    // MARK: - Conflict helpers

    /// Mirrors legacy `KeyboardShortcutSettings.Action.conflicts(with:proposedAction:configuredShortcut:)`
    /// at a coarser grain: only treat two actions as conflicting when the
    /// *configured* (effective) shortcut of the other action is not
    /// unbound and shares the same first stroke. The legacy implementation
    /// has per-action overrides (e.g. number-stack actions allow sharing),
    /// but we don't have that catalog data here, so the conservative
    /// "same first stroke && both bound" check is the best we can do.
    private func formatPlaceholder(effective: StoredShortcut?, numbered: Bool) -> String {
        let unboundLabel = String(localized: "shortcut.unbound.displayValue", defaultValue: "None")
        guard let effective else { return unboundLabel }
        if effective.isUnbound { return unboundLabel }
        return format(effective, numbered: numbered)
    }

    /// The action's effective focus predicate: its `shortcuts.when` override if
    /// present, otherwise its built-in ``ShortcutAction/defaultFocusWhenClause``.
    private func effectiveWhenClause(for action: ShortcutAction) -> ShortcutWhenClause {
        whenOverrideClauses[action.rawValue] ?? action.defaultFocusWhenClause
    }

    /// A row caption describing when a context-limited binding fires: the raw
    /// `shortcuts.when` override when one is configured, otherwise a localized
    /// description of the action's built-in focus scope. `nil` for ordinary
    /// always-on shortcuts so unscoped rows stay uncluttered.
    ///
    /// The built-in scope mapping lives in ``builtInScopeCaption(for:)`` so it can
    /// be unit-tested directly; it labels context-scoped duplicate defaults
    /// (e.g. the ⌘=/⌘-/⌘0 zoom family shared across browser, markdown, and canvas)
    /// so they read as deliberately context-separated rather than as a conflict
    /// (issue #5810).
    private func scopeCaption(for action: ShortcutAction) -> String? {
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
        return builtInScopeCaption(for: action.defaultFocusWhenClause)
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

    /// Formats a binding for display, delegating to
    /// ``shortcutDisplayString(_:numbered:)``. Pass `numbered: true` for
    /// actions whose binding stands in for the whole `1…9` digit range
    /// (see ``ShortcutAction/usesNumberedDigitMatching``) so the row reads
    /// `⌃1…9` rather than the literal single digit `⌃1`.
    private func format(_ shortcut: StoredShortcut, numbered: Bool = false) -> String {
        shortcutDisplayString(shortcut, numbered: numbered)
    }

    /// Parses `shortcuts.when` into per-action ``ShortcutWhenClause`` overrides so
    /// conflict detection can evaluate effective contexts (see
    /// ``detectConflict(for:stroke:)``). Malformed expressions are dropped.
    private func streamWhenOverrides() async {
        for await whenMap in jsonStore.values(for: catalog.shortcuts.when) {
            whenOverrideRawStrings = whenMap
            whenOverrideClauses = whenMap.compactMapValues { ShortcutWhenClause.parse($0) }
        }
    }

    private func streamBindings() async {
        streamTask?.cancel()
        let task = Task {
            for await dictionary in jsonStore.values(for: catalog.shortcuts.bindings) {
                if Task.isCancelled { break }
                let changedActionIds = Set(bindings.keys).union(dictionary.keys)
                    .filter { bindings[$0] != dictionary[$0] }
                bindings = dictionary
                // Mirror legacy `KeyboardShortcutRecorder.onChange(of:
                // shortcut)`: when an action's effective shortcut becomes
                // non-unbound (e.g. the user edited cmux.json directly to
                // restore a previously-cleared binding), drop the cached
                // restore stroke so the X/restore button flips back to
                // "Unbind" instead of stale "Restore previous shortcut".
                pruneRestoreShortcuts()
                // Mirror legacy `ShortcutRecorderSettingsControl.onChange(of: shortcut)`
                // which clears `rejectedAttempt = nil` whenever the
                // shortcut changes. Externally-edited cmux.json should
                // dismiss a stale rejection banner for that action.
                pruneConflictRejections()
                pruneNumberedDigitRejections(changedActionIds: Set(changedActionIds))
            }
        }
        streamTask = task
        await task.value
    }

    /// Drops the "Use a digit from 1 through 9" banner for an action only when
    /// *that action's* binding actually changed in the latest stream update (an
    /// external `cmux.json` edit or another settings surface restoring a usable
    /// binding). Mirrors the legacy per-action `rejectedAttempt` clear-on-change
    /// without dismissing the banner when an unrelated shortcut is saved.
    private func pruneNumberedDigitRejections(changedActionIds: Set<String>) {
        guard !numberedDigitRejections.isEmpty else { return }
        for key in Array(numberedDigitRejections) where changedActionIds.contains(key) {
            numberedDigitRejections.remove(key)
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
                continue
            }
            let effective = bindings[action.rawValue] ?? action.defaultShortcut
            if let effective, detectConflict(for: action, stroke: effective) == nil {
                conflictRejections.removeValue(forKey: key)
            } else if effective == nil {
                conflictRejections.removeValue(forKey: key)
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

    private func assign(stroke: ShortcutStroke, to action: ShortcutAction) async {
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
        await write(updated)
    }

    private func assignChord(_ chord: StoredShortcut, to action: ShortcutAction) async {
        guard action.allowsChordShortcut else {
            chordModeActions.remove(action.rawValue)
            return
        }
        guard let proposed = normalizedNumberedShortcutIfNeeded(chord, for: action) else {
            numberedDigitRejections.insert(action.rawValue)
            chordModeActions.remove(action.rawValue)
            bareKeyRejections.remove(action.rawValue)
            conflictRejections.removeValue(forKey: action.rawValue)
            return
        }
        if let conflict = detectConflict(for: action, stroke: proposed) {
            conflictRejections[action.rawValue] = conflict
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

    private func clearBinding(for action: ShortcutAction) async {
        var updated = bindings
        updated[action.rawValue] = StoredShortcut.unbound
        await write(updated)
    }

    private func restoreBinding(_ shortcut: StoredShortcut, for action: ShortcutAction) async {
        var updated = bindings
        updated[action.rawValue] = shortcut
        restoreShortcuts.removeValue(forKey: action.rawValue)
        bareKeyRejections.remove(action.rawValue)
        numberedDigitRejections.remove(action.rawValue)
        conflictRejections.removeValue(forKey: action.rawValue)
        await write(updated)
    }

    private func resetToDefault(action: ShortcutAction) async {
        var updated = bindings
        updated.removeValue(forKey: action.rawValue)
        restoreShortcuts.removeValue(forKey: action.rawValue)
        bareKeyRejections.remove(action.rawValue)
        numberedDigitRejections.remove(action.rawValue)
        conflictRejections.removeValue(forKey: action.rawValue)
        await write(updated)
    }

    private func resetAll() async {
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
}
