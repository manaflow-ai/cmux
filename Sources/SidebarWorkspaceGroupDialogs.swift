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
    worktreePath: String,
    closePlans: [VerticalTabsSidebar.ExtensionWorktreeRemovalClosePlan],
    safety: CmuxExtensionWorktreeRemovalSafety,
    removalPreview: (paths: [String], truncated: Bool, scanFailed: Bool) = ([], false, false),
    alertRunner: ((NSAlert) -> NSApplication.ModalResponse)? = nil
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
    let pathFormat = String(
        localized: "dialog.removeWorktree.message.path",
        defaultValue: "Path: %@"
    )
    lines.append(String.localizedStringWithFormat(pathFormat, worktreePath))

    let affectedWorkspaceLines = closePlans.flatMap { plan in
        plan.workspaceTitles.map { title in
            let collapsedTitle = title
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let displayTitle: String
            if collapsedTitle.isEmpty {
                displayTitle = String(
                    localized: "menu.history.untitledWorkspace",
                    defaultValue: "Untitled Workspace"
                )
            } else {
                displayTitle = collapsedTitle
            }
            let workspaceFormat = String(
                localized: "dialog.removeWorktree.affected.workspace",
                defaultValue: "\u{2022} Window %1$lld: %2$@"
            )
            return String.localizedStringWithFormat(
                workspaceFormat,
                Int64(plan.windowIndex + 1),
                displayTitle
            )
        }
    }
    if affectedWorkspaceLines.isEmpty {
        lines.append(String(
            localized: "dialog.removeWorktree.affected.none",
            defaultValue: "No open workspaces are rooted in this worktree."
        ))
    } else {
        let header = String(
            localized: "dialog.removeWorktree.affected.header",
            defaultValue: "Open workspaces rooted in this worktree will be closed:"
        )
        lines.append(([header] + affectedWorkspaceLines).joined(separator: "\n"))
    }

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
    if removalPreview.scanFailed {
        lines.append(String(
            localized: "dialog.removeWorktree.force.preview.failed",
            defaultValue: "cmux could not fully preview the paths that removal may delete."
        ))
    }
    if !removalPreview.paths.isEmpty {
        let header = String(
            localized: "dialog.removeWorktree.force.preview.header",
            defaultValue: "Removal may delete these changed, ignored, or nested-repository paths:"
        )
        let itemFormat = String(
            localized: "dialog.removeWorktree.force.preview.item",
            defaultValue: "\u{2022} %@"
        )
        let itemLines = removalPreview.paths.map { path in
            let displayPath = path
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return String.localizedStringWithFormat(itemFormat, displayPath)
        }
        lines.append(([header] + itemLines).joined(separator: "\n"))
    }
    if removalPreview.truncated {
        lines.append(String(
            localized: "dialog.removeWorktree.force.preview.truncated",
            defaultValue: "Additional paths may exist; only the first preview results are shown."
        ))
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

    let response = alertRunner?(alert) ?? runCmuxModalAlert(alert)
    return response == .alertFirstButtonReturn
}

/// Confirmation dialog for retrying a refused worktree removal with `--force`.
@MainActor
func confirmForceRemoveExtensionWorktreeAfterFailure(
    worktreeName: String,
    message: String,
    previewPaths: [String],
    previewTruncated: Bool,
    previewScanFailed: Bool,
    alertRunner: ((NSAlert) -> NSApplication.ModalResponse)? = nil
) -> Bool {
    let alert = NSAlert()
    alert.messageText = String(
        localized: "dialog.removeWorktree.force.title",
        defaultValue: "Force remove this worktree?"
    )
    let format = String(
        localized: "dialog.removeWorktree.force.message",
        defaultValue: "Git could not remove the worktree \u{201C}%@\u{201D} without force:\n\n%@"
    )
    var lines = [String.localizedStringWithFormat(format, worktreeName, message)]
    if previewScanFailed {
        lines.append(String(
            localized: "dialog.removeWorktree.force.preview.failed",
            defaultValue: "cmux could not fully preview the paths that removal may delete."
        ))
    }
    if previewPaths.isEmpty && !previewScanFailed {
        lines.append(String(
            localized: "dialog.removeWorktree.force.preview.empty",
            defaultValue: "The bounded preview did not find changed, ignored, or nested-repository paths beyond the worktree itself."
        ))
    } else {
        let header = String(
            localized: "dialog.removeWorktree.force.preview.header",
            defaultValue: "Removal may delete these changed, ignored, or nested-repository paths:"
        )
        let itemFormat = String(
            localized: "dialog.removeWorktree.force.preview.item",
            defaultValue: "\u{2022} %@"
        )
        let itemLines = previewPaths.map { path in
            let displayPath = path
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return String.localizedStringWithFormat(itemFormat, displayPath)
        }
        lines.append(([header] + itemLines).joined(separator: "\n"))
    }
    if previewTruncated {
        lines.append(String(
            localized: "dialog.removeWorktree.force.preview.truncated",
            defaultValue: "Additional paths may exist; only the first preview results are shown."
        ))
    }
    lines.append(String(
        localized: "dialog.removeWorktree.force.warning",
        defaultValue: "Force removal deletes the working directory, including anything not shown above."
    ))
    alert.informativeText = lines.joined(separator: "\n\n")
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

    let response = alertRunner?(alert) ?? runCmuxModalAlert(alert)
    return response == .alertFirstButtonReturn
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
