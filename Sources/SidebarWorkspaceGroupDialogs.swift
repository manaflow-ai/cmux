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
func confirmDeleteWorkspaceGroup(groupName: String, memberCount: Int) -> Bool {
    let title = String(
        localized: "dialog.deleteGroup.title",
        defaultValue: "Delete this group?"
    )
    let message: String?
    if memberCount <= 0 {
        message = nil
    } else if memberCount == 1 {
        let format = String(
            localized: "dialog.deleteGroup.message.lone",
            defaultValue: "Delete the group \u{201C}%@\u{201D} and close its workspace?"
        )
        message = String.localizedStringWithFormat(format, groupName)
    } else if memberCount == 2 {
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
        message = String.localizedStringWithFormat(format, groupName, memberCount)
    }
    let alert = NSAlert()
    alert.messageText = title
    if let message {
        alert.informativeText = message
    }
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
