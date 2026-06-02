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
                resetDefaultsRow
                SettingsCardDivider()
                // Filter out actions that live in their own section
                // (Global Hotkey owns the system-wide chord), then
                // re-order so the colocated right-sidebar/find actions
                // sit next to the unread navigation actions — matches
                // legacy `KeyboardShortcutSettings.settingsVisibleActions`
                // / `orderedSettingsVisibleActions`.
                // ~166 recorder rows, each AppKit-backed — the one heavy
                // list in Settings. The detail stack is eager (so every
                // search anchor stays scroll-addressable), which would
                // otherwise build all of these on window open and cost
                // ~2s. These per-shortcut rows aren't search anchors (only
                // the enclosing card is), so a LazyVStack here defers them
                // until the section scrolls into view without affecting any
                // scroll/highlight target.
                let actions = Self.settingsVisibleActions
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
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.leading, 2)
                .accessibilityIdentifier("ShortcutRecordingHint")
        }
        .task { await streamBindings() }
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
                .font(.caption)
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
        let effective = override ?? action.defaultStroke.map { StoredShortcut(first: $0) }
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
                let conflictEffective = conflictOverride ?? conflict.defaultStroke.map { StoredShortcut(first: $0) }
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

        let subtitle: String? = nil
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: subtitle == nil ? .center : .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(action.displayName)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
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
                        .font(.caption)
                        .foregroundStyle(.red)

                    Text(validationMessage)
                        .font(.caption)
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
                    .font(.caption)
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

    /// Mirrors legacy `KeyboardShortcutSettings.settingsVisibleActions`:
    /// filters out `.showHideAllWindows` (owned by Global Hotkey section)
    /// then re-orders so `focusRightSidebar`, `toggleRightSidebar`, and
    /// `findInDirectory` sit immediately after `markOldestUnreadAndJumpNext`
    /// or `jumpToUnread` (the unread navigation cluster), so colocated
    /// sidebar/find shortcuts appear together in the settings UI.
    private static var settingsVisibleActions: [ShortcutAction] {
        let base = ShortcutAction.allCases.filter { $0 != .showHideAllWindows }
        let colocated: [ShortcutAction] = [
            .focusRightSidebar,
            .toggleRightSidebar,
            .findInDirectory,
        ].filter(base.contains)
        let colocatedSet = Set(colocated)
        let remaining = base.filter { !colocatedSet.contains($0) }

        guard let anchorIndex = remaining.firstIndex(of: .markOldestUnreadAndJumpNext)
            ?? remaining.firstIndex(of: .jumpToUnread) else {
            return colocated + remaining
        }

        var ordered = remaining
        ordered.insert(contentsOf: colocated, at: anchorIndex + 1)
        return ordered
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

    private func detectConflict(for action: ShortcutAction, stroke: StoredShortcut) -> ShortcutAction? {
        for other in ShortcutAction.allCases where other != action {
            let override = bindings[other.rawValue]
            let effective = override ?? other.defaultStroke.map { StoredShortcut(first: $0) }
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

    private func streamBindings() async {
        streamTask?.cancel()
        let task = Task {
            for await dictionary in jsonStore.values(for: catalog.shortcuts.bindings) {
                if Task.isCancelled { break }
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
            }
        }
        streamTask = task
        await task.value
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
            let effective = bindings[action.rawValue] ?? action.defaultStroke.map { StoredShortcut(first: $0) }
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
        if let conflict = detectConflict(for: action, stroke: chord) {
            conflictRejections[action.rawValue] = conflict
            chordModeActions.remove(action.rawValue)
            bareKeyRejections.remove(action.rawValue)
            numberedDigitRejections.remove(action.rawValue)
            return
        }
        var updated = bindings
        updated[action.rawValue] = chord
        chordModeActions.remove(action.rawValue)
        restoreShortcuts.removeValue(forKey: action.rawValue)
        bareKeyRejections.remove(action.rawValue)
        numberedDigitRejections.remove(action.rawValue)
        conflictRejections.removeValue(forKey: action.rawValue)
        await write(updated)
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
