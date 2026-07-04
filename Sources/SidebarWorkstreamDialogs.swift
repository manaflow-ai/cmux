import AppKit

/// Prompt for a new workstream name and create it. A blank name uses the
/// localized "Workstream N" auto-name. Returns the new workstream's id, or nil
/// if the user cancelled.
@MainActor
@discardableResult
func presentCreateWorkstreamPrompt(tabManager: TabManager) -> UUID? {
    let alert = NSAlert()
    alert.messageText = String(
        localized: "workstream.create.title",
        defaultValue: "New Workstream"
    )
    alert.informativeText = String(
        localized: "workstream.create.message",
        defaultValue: "Name this workstream (a feature, epic, or initiative)."
    )
    alert.addButton(
        withTitle: String(localized: "workstream.create.confirm", defaultValue: "Create")
    )
    alert.addButton(
        withTitle: String(localized: "common.cancel", defaultValue: "Cancel")
    )
    let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
    input.placeholderString = String(
        localized: "workstream.create.placeholder",
        defaultValue: "Workstream name"
    )
    alert.accessoryView = input
    let alertWindow = alert.window
    alertWindow.initialFirstResponder = input
    DispatchQueue.main.async {
        alertWindow.makeFirstResponder(input)
    }
    guard runCmuxModalAlert(alert) == .alertFirstButtonReturn else { return nil }
    return tabManager.createWorkstream(name: input.stringValue)
}

/// Prompt for a new name and rename the workstream.
@MainActor
func presentRenameWorkstreamPrompt(
    tabManager: TabManager,
    workstreamId: UUID,
    currentName: String
) {
    let alert = NSAlert()
    alert.messageText = String(
        localized: "workstream.rename.title",
        defaultValue: "Rename Workstream"
    )
    alert.informativeText = String(
        localized: "workstream.rename.message",
        defaultValue: "Enter a new name for this workstream."
    )
    alert.addButton(
        withTitle: String(localized: "workstream.rename.confirm", defaultValue: "Rename")
    )
    alert.addButton(
        withTitle: String(localized: "common.cancel", defaultValue: "Cancel")
    )
    let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
    input.stringValue = currentName
    input.placeholderString = String(
        localized: "workstream.rename.placeholder",
        defaultValue: "Workstream name"
    )
    alert.accessoryView = input
    let alertWindow = alert.window
    alertWindow.initialFirstResponder = input
    DispatchQueue.main.async {
        alertWindow.makeFirstResponder(input)
        input.selectText(nil)
    }
    guard runCmuxModalAlert(alert) == .alertFirstButtonReturn else { return }
    tabManager.renameWorkstream(id: workstreamId, name: input.stringValue)
}

/// Confirm deleting a workstream. Deleting only dissolves the workstream —
/// member workspaces are kept (returned to the top level), so the warning text
/// reflects that this is non-destructive to the workspaces themselves.
@MainActor
func confirmDeleteWorkstream(workstreamName: String, workspaceCount: Int) -> Bool {
    let alert = NSAlert()
    alert.messageText = String(
        localized: "workstream.delete.title",
        defaultValue: "Delete this workstream?"
    )
    if workspaceCount == 0 {
        let format = String(
            localized: "workstream.delete.message.empty",
            defaultValue: "Delete the workstream \u{201C}%@\u{201D}?"
        )
        alert.informativeText = String.localizedStringWithFormat(format, workstreamName)
    } else {
        let format = workspaceCount == 1
            ? String(
                localized: "workstream.delete.message.one",
                defaultValue: "Delete the workstream \u{201C}%1$@\u{201D}? Its %2$lld workspace is kept and returns to the top level."
            )
            : String(
                localized: "workstream.delete.message.other",
                defaultValue: "Delete the workstream \u{201C}%1$@\u{201D}? Its %2$lld workspaces are kept and return to the top level."
            )
        alert.informativeText = String.localizedStringWithFormat(format, workstreamName, workspaceCount)
    }
    alert.alertStyle = .warning
    alert.addButton(
        withTitle: String(localized: "workstream.delete.confirm", defaultValue: "Delete")
    )
    alert.addButton(
        withTitle: String(localized: "common.cancel", defaultValue: "Cancel")
    )
    if let confirmButton = alert.buttons.first {
        confirmButton.keyEquivalent = "\r"
        confirmButton.keyEquivalentModifierMask = []
    }
    if let cancelButton = alert.buttons.dropFirst().first {
        cancelButton.keyEquivalent = "\u{1b}"
    }
    return runCmuxModalAlert(alert) == .alertFirstButtonReturn
}
