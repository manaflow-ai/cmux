import SwiftUI

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
            KeyboardShortcutSettings.setShortcut(newValue, for: action)
        }
        .onReceive(NotificationCenter.default.publisher(for: KeyboardShortcutSettings.didChangeNotification)) { _ in
            let latest = KeyboardShortcutSettings.shortcut(for: action)
            let latestManagedState = KeyboardShortcutSettings.isManagedBySettingsFile(action)
            if latest != shortcut {
                shortcut = latest
            }
            if latestManagedState != isManagedBySettingsFile {
                isManagedBySettingsFile = latestManagedState
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
