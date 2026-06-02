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

    let response = alert.runModal()
    guard response == .alertFirstButtonReturn else { return }
    tabManager.renameWorkspaceGroup(groupId: groupId, name: input.stringValue)
}

@MainActor
func presentSidebarWorkspaceGroupIconPrompt(
    tabManager: TabManager,
    groupId: UUID,
    currentSymbol: String?
) {
    var nextValue = RenderableSystemSymbol.normalized(currentSymbol) ?? ""
    while true {
        let alert = NSAlert()
        alert.messageText = String(
            localized: "workspaceGroup.icon.title",
            defaultValue: "Set Group Icon"
        )
        alert.informativeText = String(
            localized: "workspaceGroup.icon.message",
            defaultValue: "Enter an SF Symbol name for this group. Leave it empty to use the configured or default icon."
        )
        alert.addButton(
            withTitle: String(localized: "workspaceGroup.icon.confirm", defaultValue: "Set Icon")
        )
        alert.addButton(
            withTitle: String(localized: "workspaceGroup.icon.clear", defaultValue: "Clear Icon")
        )
        alert.addButton(
            withTitle: String(localized: "common.cancel", defaultValue: "Cancel")
        )

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        input.stringValue = nextValue
        input.placeholderString = String(
            localized: "workspaceGroup.icon.placeholder",
            defaultValue: "folder.fill"
        )
        alert.accessoryView = input
        let alertWindow = alert.window
        alertWindow.initialFirstResponder = input
        Task { @MainActor in
            alertWindow.makeFirstResponder(input)
            input.selectText(nil)
        }

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            guard let symbol = RenderableSystemSymbol.trimmed(input.stringValue) else {
                tabManager.setWorkspaceGroupIcon(groupId: groupId, symbol: nil)
                return
            }
            guard RenderableSystemSymbol.isRenderable(symbol) else {
                presentSidebarWorkspaceGroupInvalidIconAlert(symbol: symbol)
                nextValue = symbol
                continue
            }
            tabManager.setWorkspaceGroupIcon(groupId: groupId, symbol: symbol)
            return
        case .alertSecondButtonReturn:
            tabManager.setWorkspaceGroupIcon(groupId: groupId, symbol: nil)
            return
        default:
            return
        }
    }
}

@MainActor
private func presentSidebarWorkspaceGroupInvalidIconAlert(symbol: String) {
    let alert = NSAlert()
    alert.messageText = String(
        localized: "workspaceGroup.icon.invalid.title",
        defaultValue: "Icon Not Found"
    )
    let format = String(
        localized: "workspaceGroup.icon.invalid.message",
        defaultValue: "\"%@\" is not an SF Symbol name available on this Mac."
    )
    alert.informativeText = String.localizedStringWithFormat(format, symbol)
    alert.addButton(
        withTitle: String(localized: "settings.error.alert.dismiss", defaultValue: "OK")
    )
    alert.runModal()
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
    return alert.runModal() == .alertFirstButtonReturn
}
