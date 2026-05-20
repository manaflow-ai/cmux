import SwiftUI

struct ShortcutRecorderValidationPresentation: Equatable {
    let message: String
    let swapButtonTitle: String?
    let undoButtonTitle: String
    let canSwap: Bool

    init?(
        attempt: ShortcutRecorderRejectedAttempt?,
        action: KeyboardShortcutSettings.Action,
        currentShortcut: StoredShortcut,
        shortcutForAction: (KeyboardShortcutSettings.Action) -> StoredShortcut = KeyboardShortcutSettings.shortcut(for:),
        isManagedBySettingsFile: (KeyboardShortcutSettings.Action) -> Bool = KeyboardShortcutSettings.isManagedBySettingsFile
    ) {
        guard let attempt else { return nil }
        guard Self.shouldPresent(
            attempt: attempt,
            action: action,
            shortcutForAction: shortcutForAction
        ) else {
            return nil
        }

        let canSwap = Self.canSwapConflict(
            attempt: attempt,
            action: action,
            currentShortcut: currentShortcut,
            shortcutForAction: shortcutForAction,
            isManagedBySettingsFile: isManagedBySettingsFile
        )

        self.message = Self.message(
            for: attempt.reason,
            canSwap: canSwap,
            shortcutForAction: shortcutForAction
        )
        self.swapButtonTitle = canSwap
            ? String(localized: "shortcut.recorder.swap", defaultValue: "Swap")
            : nil
        self.undoButtonTitle = String(localized: "shortcut.recorder.undo", defaultValue: "Undo")
        self.canSwap = canSwap
    }

    private static func shouldPresent(
        attempt: ShortcutRecorderRejectedAttempt,
        action: KeyboardShortcutSettings.Action,
        shortcutForAction: (KeyboardShortcutSettings.Action) -> StoredShortcut
    ) -> Bool {
        guard case let .conflictsWithAction(conflictingAction) = attempt.reason else {
            return true
        }
        guard let proposedShortcut = attempt.proposedShortcut else {
            return false
        }

        return conflictingAction.conflicts(
            with: proposedShortcut,
            proposedAction: action,
            configuredShortcut: shortcutForAction(conflictingAction)
        )
    }

    private static func message(
        for reason: KeyboardShortcutSettings.ShortcutRecordingRejection,
        canSwap: Bool,
        shortcutForAction: (KeyboardShortcutSettings.Action) -> StoredShortcut
    ) -> String {
        switch reason {
        case .bareKeyNotAllowed:
            return String(
                localized: "shortcut.recorder.error.bareKeyNotAllowed",
                defaultValue: "Shortcuts must include ⌘ ⌥ ⌃ or ⇧"
            )
        case let .conflictsWithAction(conflictingAction):
            let conflictingShortcut = conflictingAction.displayedShortcutString(
                for: shortcutForAction(conflictingAction)
            )
            let format: String
            if canSwap {
                format = String(
                    localized: "shortcut.recorder.error.conflictsWithAction.swap",
                    defaultValue: "This shortcut conflicts with %@ (%@). Swap shortcuts?"
                )
            } else {
                format = String(
                    localized: "shortcut.recorder.error.conflictsWithAction",
                    defaultValue: "This shortcut conflicts with %@ (%@)."
                )
            }
            return String.localizedStringWithFormat(format, conflictingAction.label, conflictingShortcut)
        case .reservedBySystem:
            return String(
                localized: "shortcut.recorder.error.reservedBySystem",
                defaultValue: "This keystroke is reserved by macOS."
            )
        case .numberedShortcutRequiresDigit:
            return String(
                localized: "shortcut.recorder.error.numberedShortcutRequiresDigit",
                defaultValue: "Use a digit from 1 through 9."
            )
        case .systemWideHotkeyRequiresModifier:
            return String(
                localized: "shortcut.recorder.error.systemWideHotkeyRequiresModifier",
                defaultValue: "System-wide hotkeys must include Command, Option, or Control."
            )
        }
    }

    private static func canSwapConflict(
        attempt: ShortcutRecorderRejectedAttempt,
        action: KeyboardShortcutSettings.Action,
        currentShortcut: StoredShortcut,
        shortcutForAction: (KeyboardShortcutSettings.Action) -> StoredShortcut,
        isManagedBySettingsFile: (KeyboardShortcutSettings.Action) -> Bool
    ) -> Bool {
        guard case let .conflictsWithAction(conflictingAction) = attempt.reason,
              let proposedShortcut = attempt.proposedShortcut else {
            return false
        }

        guard conflictingAction.conflicts(
            with: proposedShortcut,
            proposedAction: action,
            configuredShortcut: shortcutForAction(conflictingAction)
        ) else {
            return false
        }

        guard !isManagedBySettingsFile(action),
              !isManagedBySettingsFile(conflictingAction) else {
            return false
        }

        guard case .accepted = action.resolvedRecordedShortcutIgnoringConflicts(proposedShortcut),
              case .accepted = conflictingAction.resolvedRecordedShortcutIgnoringConflicts(currentShortcut) else {
            return false
        }

        return true
    }
}

struct ShortcutSettingRow: View {
    let action: KeyboardShortcutSettings.Action
    @State private var shortcut: StoredShortcut
    @State private var isManagedBySettingsFile: Bool

    init(action: KeyboardShortcutSettings.Action) {
        self.action = action
        _shortcut = State(initialValue: KeyboardShortcutSettings.shortcut(for: action))
        _isManagedBySettingsFile = State(initialValue: KeyboardShortcutSettings.isManagedBySettingsFile(action))
    }

    var body: some View {
        ShortcutRecorderSettingsControl(
            action: action,
            shortcut: $shortcut,
            subtitle: isManagedBySettingsFile ? KeyboardShortcutSettings.settingsFileManagedSubtitle(for: action) : nil,
            displayString: { action.displayedShortcutString(for: $0) },
            isDisabled: isManagedBySettingsFile
        )
        .onChange(of: shortcut) { _, newValue in
            guard !isManagedBySettingsFile else { return }
            KeyboardShortcutSettings.setShortcut(newValue, for: action)
        }
        .onReceive(NotificationCenter.default.publisher(for: KeyboardShortcutSettings.didChangeNotification)) { _ in
            let latest = KeyboardShortcutSettings.shortcut(for: action)
            let latestManagedState = KeyboardShortcutSettings.isManagedBySettingsFile(action)
            if latestManagedState != isManagedBySettingsFile {
                isManagedBySettingsFile = latestManagedState
            }
            if latest != shortcut {
                shortcut = latest
            }
        }
    }
}

struct ShortcutRecorderSettingsControl: View {
    let action: KeyboardShortcutSettings.Action
    @Binding var shortcut: StoredShortcut
    var subtitle: String? = nil
    var displayString: (StoredShortcut) -> String = { $0.displayString }
    var isDisabled: Bool = false

    @State private var rejectedAttempt: ShortcutRecorderRejectedAttempt?

    var body: some View {
        KeyboardShortcutRecorder(
            label: action.label,
            subtitle: subtitle,
            shortcut: $shortcut,
            displayString: displayString,
            transformRecordedShortcut: { action.normalizedRecordedShortcutResult($0) },
            validationMessage: validationPresentation?.message,
            validationButtonTitle: validationPresentation?.swapButtonTitle,
            onValidationButtonPressed: validationPresentation?.canSwap == true
                ? { swapConflictingShortcut() }
                : nil,
            undoButtonTitle: validationPresentation?.undoButtonTitle,
            onUndoButtonPressed: rejectedAttempt != nil ? { rejectedAttempt = nil } : nil,
            hasPendingRejection: rejectedAttempt != nil,
            isDisabled: isDisabled,
            onRecorderFeedbackChanged: { rejectedAttempt = $0 }
        )
        .onChange(of: shortcut) { _, _ in
            rejectedAttempt = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: KeyboardShortcutRecorderActivity.didChangeNotification)) { _ in
            if KeyboardShortcutRecorderActivity.isAnyRecorderActive {
                rejectedAttempt = nil
            }
        }
    }

    private var validationPresentation: ShortcutRecorderValidationPresentation? {
        ShortcutRecorderValidationPresentation(
            attempt: rejectedAttempt,
            action: action,
            currentShortcut: shortcut
        )
    }

    private func swapConflictingShortcut() {
        guard case let .conflictsWithAction(conflictingAction)? = rejectedAttempt?.reason,
              let proposedShortcut = rejectedAttempt?.proposedShortcut else {
            return
        }

        KeyboardShortcutRecorderActivity.stopAllRecording()

        let previousShortcut = shortcut
        let didSwap = KeyboardShortcutSettings.swapShortcutConflict(
            proposedShortcut: proposedShortcut,
            currentAction: action,
            conflictingAction: conflictingAction,
            previousShortcut: previousShortcut
        )
        guard didSwap else { return }
        shortcut = KeyboardShortcutSettings.shortcut(for: action)
        rejectedAttempt = nil
    }
}
