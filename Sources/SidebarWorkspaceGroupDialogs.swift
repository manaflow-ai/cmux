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

/// Confirmation dialog for removing a cmux-managed worktree from the Project
/// Worktrees sidebar. Surfaces uncommitted/unpushed work as a warning and
/// always requires an explicit confirmation before deleting the directory.
@MainActor
func confirmRemoveExtensionWorktree(
    worktreeName: String,
    safety: CmuxExtensionWorktreeRemovalSafety
) -> Bool {
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
    if safety.hasUnreferencedDetachedHead {
        lines.append(String(
            localized: "dialog.removeWorktree.warning.detached",
            defaultValue: "HEAD is detached and its current commit is not on a local branch or tag; removing the worktree may make that committed work hard to recover."
        ))
    }
    if safety.hasUnpushedCommits {
        let unpushed: String
        if safety.unpushedCommitCount == 1 {
            unpushed = String(
                localized: "dialog.removeWorktree.warning.unpushed.one",
                defaultValue: "It has 1 commit that isn\u{2019}t on any remote; the branch is kept after removal."
            )
        } else {
            let format = String(
                localized: "dialog.removeWorktree.warning.unpushed.other",
                defaultValue: "It has %lld commits that aren\u{2019}t on any remote; the branch is kept after removal."
            )
            unpushed = String.localizedStringWithFormat(format, safety.unpushedCommitCount)
        }
        lines.append(unpushed)
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

    if let removeButton = alert.buttons.first {
        removeButton.keyEquivalent = "\r"
        removeButton.keyEquivalentModifierMask = []
        alert.window.defaultButtonCell = removeButton.cell as? NSButtonCell
        alert.window.initialFirstResponder = removeButton
    }
    if let cancelButton = alert.buttons.dropFirst().first {
        cancelButton.keyEquivalent = "\u{1b}"
    }

    return runCmuxModalAlert(alert) == .alertFirstButtonReturn
}

/// Confirmation dialog for retrying a refused worktree removal with `--force`.
@MainActor
func confirmForceRemoveExtensionWorktreeAfterFailure(worktreeName: String, message: String) -> Bool {
    let alert = NSAlert()
    alert.messageText = String(
        localized: "dialog.removeWorktree.force.title",
        defaultValue: "Force remove this worktree?"
    )
    let format = String(
        localized: "dialog.removeWorktree.force.message",
        defaultValue: "Git could not remove the worktree \u{201C}%@\u{201D} without force:\n\n%@\n\nForce removal deletes the working directory even if it contains ignored files, nested repositories, or other files Git refuses to remove normally."
    )
    alert.informativeText = String.localizedStringWithFormat(format, worktreeName, message)
    alert.alertStyle = .warning
    alert.addButton(withTitle: String(
        localized: "dialog.removeWorktree.force.remove",
        defaultValue: "Force Remove"
    ))
    alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))

    if let forceButton = alert.buttons.first {
        forceButton.keyEquivalent = "\r"
        forceButton.keyEquivalentModifierMask = []
        alert.window.defaultButtonCell = forceButton.cell as? NSButtonCell
        alert.window.initialFirstResponder = forceButton
    }
    if let cancelButton = alert.buttons.dropFirst().first {
        cancelButton.keyEquivalent = "\u{1b}"
    }

    return runCmuxModalAlert(alert) == .alertFirstButtonReturn
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
