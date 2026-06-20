import AppKit

@MainActor
func presentSidebarWorkspaceGroupRenamePrompt(
    tabManager: TabManager,
    groupId: UUID,
    currentName: String
) {
    let alert = NSAlert()
    alert.messageText = String(
        localized: "workspaceGroup.rename.title",
        defaultValue: "Rename Group"
    )
    alert.informativeText = String(
        localized: "workspaceGroup.rename.message",
        defaultValue: "Enter a new name for this group."
    )
    alert.addButton(
        withTitle: String(localized: "workspaceGroup.rename.confirm", defaultValue: "Rename")
    )
    alert.addButton(
        withTitle: String(localized: "common.cancel", defaultValue: "Cancel")
    )
    let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
    input.stringValue = currentName
    input.placeholderString = String(
        localized: "workspaceGroup.rename.placeholder",
        defaultValue: "Group name"
    )
    alert.accessoryView = input

    let alertWindow = alert.window
    alertWindow.initialFirstResponder = input
    DispatchQueue.main.async {
        alertWindow.makeFirstResponder(input)
        input.selectText(nil)
    }

    let response = runCmuxModalAlert(alert)
    guard response == .alertFirstButtonReturn else { return }
    tabManager.renameWorkspaceGroup(groupId: groupId, name: input.stringValue)
}

/// Confirmation dialog for destructive group deletion.
@MainActor
func confirmDeleteWorkspaceGroup(groupName: String, otherMemberCount: Int) -> Bool {
    let title = String(
        localized: "dialog.deleteGroup.title",
        defaultValue: "Delete this group?"
    )
    let message: String
    if otherMemberCount == 0 {
        let format = String(
            localized: "dialog.deleteGroup.message.lone",
            defaultValue: "Delete the group \u{201C}%@\u{201D} and close its workspace?"
        )
        message = String.localizedStringWithFormat(format, groupName)
    } else if otherMemberCount == 1 {
        let format = String(
            localized: "dialog.deleteGroup.message.one",
            defaultValue: "Delete the group \u{201C}%@\u{201D} and close its 2 workspaces?"
        )
        message = String.localizedStringWithFormat(format, groupName)
    } else {
        let format = String(
            localized: "dialog.deleteGroup.message.many",
            defaultValue: "Delete the group \u{201C}%1$@\u{201D} and close its %2$lld workspaces?"
        )
        message = String.localizedStringWithFormat(format, groupName, otherMemberCount + 1)
    }
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.alertStyle = .warning
    alert.addButton(
        withTitle: String(
            localized: "dialog.deleteGroup.confirm",
            defaultValue: "Delete"
        )
    )
    alert.addButton(
        withTitle: String(localized: "common.cancel", defaultValue: "Cancel")
    )
    if let confirmButton = alert.buttons.first {
        confirmButton.keyEquivalent = "\r"
        confirmButton.keyEquivalentModifierMask = []
        alert.window.defaultButtonCell = confirmButton.cell as? NSButtonCell
        alert.window.initialFirstResponder = confirmButton
    }
    if let cancelButton = alert.buttons.dropFirst().first {
        cancelButton.keyEquivalent = "\u{1b}"
    }
    return runCmuxModalAlert(alert) == .alertFirstButtonReturn
}

/// The outcome of the Project Worktrees removal confirmation dialog.
struct ExtensionWorktreeRemovalDecision {
    /// Whether the user chose to remove the worktree.
    var confirmed: Bool
    /// Whether the user asked to suppress future confirmations. Only ever true
    /// for a clean removal — the dialog hides the checkbox when there is
    /// unsaved or unpushed work so data-loss warnings can't be silenced.
    var suppressFuturePrompts: Bool
}

/// Confirmation dialog for removing a cmux-managed worktree from the Project
/// Worktrees sidebar. Surfaces uncommitted/unpushed work as a warning and
/// offers a "Don't ask again" checkbox only when the worktree is clean.
@MainActor
func confirmRemoveExtensionWorktree(
    worktreeName: String,
    safety: CmuxExtensionWorktreeRemovalSafety
) -> ExtensionWorktreeRemovalDecision {
    let alert = NSAlert()
    alert.messageText = String(
        localized: "dialog.removeWorktree.title",
        defaultValue: "Remove this worktree?"
    )

    var lines: [String] = []
    let base = String(
        localized: "dialog.removeWorktree.message.base",
        defaultValue: "Removing the worktree \u{201C}%@\u{201D} deletes its working directory on disk."
    )
    lines.append(String.localizedStringWithFormat(base, worktreeName))
    if safety.inspectionFailed {
        lines.append(String(
            localized: "dialog.removeWorktree.warning.unknown",
            defaultValue: "cmux couldn\u{2019}t check it for unsaved changes, so anything uncommitted may be lost."
        ))
    }
    if safety.hasUncommittedChanges {
        lines.append(String(
            localized: "dialog.removeWorktree.warning.uncommitted",
            defaultValue: "It has uncommitted changes that will be permanently lost."
        ))
    }
    if safety.hasUnpushedCommits {
        let unpushed = String(
            localized: "dialog.removeWorktree.warning.unpushed",
            defaultValue: "It has %lld commit(s) that aren\u{2019}t on any remote; the branch is kept after removal."
        )
        lines.append(String.localizedStringWithFormat(unpushed, safety.unpushedCommitCount))
    }
    if safety.isClean {
        lines.append(String(
            localized: "dialog.removeWorktree.message.cleanFooter",
            defaultValue: "Committed work on its branch is kept."
        ))
    }
    alert.informativeText = lines.joined(separator: "\n\n")
    alert.alertStyle = .warning

    alert.addButton(withTitle: String(
        localized: "dialog.removeWorktree.remove",
        defaultValue: "Remove"
    ))
    alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))

    let suppressionButton: NSButton?
    if safety.isClean {
        let button = NSButton(
            checkboxWithTitle: String(localized: "dialog.dontAskAgain", defaultValue: "Don\u{2019}t ask again"),
            target: nil,
            action: nil
        )
        button.state = .off
        alert.accessoryView = button
        suppressionButton = button
    } else {
        suppressionButton = nil
    }

    if let removeButton = alert.buttons.first {
        removeButton.keyEquivalent = "\r"
        removeButton.keyEquivalentModifierMask = []
        alert.window.defaultButtonCell = removeButton.cell as? NSButtonCell
        alert.window.initialFirstResponder = removeButton
    }
    if let cancelButton = alert.buttons.dropFirst().first {
        cancelButton.keyEquivalent = "\u{1b}"
    }

    let confirmed = runCmuxModalAlert(alert) == .alertFirstButtonReturn
    return ExtensionWorktreeRemovalDecision(
        confirmed: confirmed,
        suppressFuturePrompts: confirmed && suppressionButton?.state == .on
    )
}

/// Surfaces a worktree-removal failure (e.g. git refused the operation).
@MainActor
func presentExtensionWorktreeRemovalFailure(worktreeName: String, message: String) {
    let alert = NSAlert()
    alert.messageText = String(
        localized: "dialog.removeWorktree.failure.title",
        defaultValue: "Couldn\u{2019}t remove the worktree"
    )
    let format = String(
        localized: "dialog.removeWorktree.failure.message",
        defaultValue: "cmux could not remove the worktree \u{201C}%@\u{201D}.\n\n%@"
    )
    alert.informativeText = String.localizedStringWithFormat(format, worktreeName, message)
    alert.alertStyle = .warning
    alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))
    _ = runCmuxModalAlert(alert)
}
