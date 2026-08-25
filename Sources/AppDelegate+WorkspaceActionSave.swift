import AppKit
import Foundation

// MARK: - Save Workspace Layout (new-workspace plus-button menu)

/// Payload for delete-action menu items (submenu entries and ⌥-alternates).
@MainActor
final class WorkspaceActionDeleteBox: NSObject {
    let windowId: UUID
    let actionID: String
    let actionTitle: String

    init(windowId: UUID, actionID: String, actionTitle: String) {
        self.windowId = windowId
        self.actionID = actionID
        self.actionTitle = actionTitle
    }
}

@MainActor
final class WorkspaceDefaultLayoutBox: NSObject {
    let windowId: UUID
    let actionID: String?

    init(windowId: UUID, actionID: String?) {
        self.windowId = windowId
        self.actionID = actionID
    }
}

extension AppDelegate {

    /// Actions defined in the global config (where saved workspace layouts
    /// write) are deletable from the UI; project-local and built-in actions
    /// are not.
    func isDeletableGlobalAction(
        _ action: CmuxResolvedConfigAction,
        cmuxConfigStore: CmuxConfigStore
    ) -> Bool {
        guard let sourcePath = action.actionSourcePath else { return false }
        func canonical(_ path: String) -> String {
            URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        }
        return canonical(sourcePath) == canonical(cmuxConfigStore.globalConfigPath)
    }

    func openWorkspaceLayoutsCustomization() {
        // Open inside cmux's own file editor rather than an external app — the
        // OS-default handler for .json can be Xcode, which is never what
        // "customize my workspace layouts" means.
        let configURL = SidebarWorkspaceGroupConfigOpener.materializedCmuxConfigURL()
        let targetContext = [
            NSApp.keyWindow,
            NSApp.mainWindow,
            shortcutRoutingActiveWindow,
        ]
        .compactMap { contextForMainWindow($0) }
        .first
        // Fail closed: if no active-window candidate resolves to a main-window
        // context, don't target an arbitrary workspace/pane. Fall through to the
        // guard's editor fallback below instead.

        guard let context = targetContext,
              let workspace = context.tabManager.selectedWorkspace,
              let paneId = workspace.bonsplitController.focusedPaneId
                  ?? workspace.bonsplitController.allPaneIds.first,
              !workspace.openFileSurfaces(
                  inPane: paneId,
                  filePaths: [configURL.path],
                  focus: true,
                  reuseExisting: true
              ).isEmpty else {
            SidebarWorkspaceGroupConfigOpener.openCmuxConfigInEditor()
            return
        }
    }

    @objc func deleteWorkspaceConfigActionMenuItem(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? WorkspaceActionDeleteBox,
              let context = mainWindowContexts.values.first(where: { $0.windowId == box.windowId }),
              let cmuxConfigStore = context.cmuxConfigStore,
              let window = resolvedWindow(for: context) else {
            NSSound.beep()
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            localized: "dialog.deleteWorkspaceLayout.title",
            defaultValue: "Delete Workspace Layout?"
        )
        let messageFormat = String(
            localized: "dialog.deleteWorkspaceLayout.message",
            defaultValue: "Removes “%1$@” from %2$@. Workspaces it already created stay open."
        )
        alert.informativeText = String(
            format: messageFormat,
            box.actionTitle,
            (cmuxConfigStore.globalConfigPath as NSString).abbreviatingWithTildeInPath
        )
        let deleteButton = alert.addButton(withTitle: String(
            localized: "dialog.deleteWorkspaceLayout.delete",
            defaultValue: "Delete"
        ))
        deleteButton.hasDestructiveAction = true
        alert.addButton(withTitle: String(
            localized: "dialog.deleteWorkspaceLayout.cancel",
            defaultValue: "Cancel"
        ))
        alert.beginSheetModal(for: window) { [weak window, weak cmuxConfigStore] response in
            guard response == .alertFirstButtonReturn, let cmuxConfigStore else { return }
            do {
                try CmuxConfigActionSaver.deleteAction(
                    id: box.actionID,
                    globalConfigPath: cmuxConfigStore.globalConfigPath
                )
                cmuxConfigStore.loadAll()
#if DEBUG
                cmuxDebugLog("deleteWorkspaceAction.deleted id=\(box.actionID)")
#endif
            } catch {
                guard let window else { return }
                let errorAlert = NSAlert()
                errorAlert.alertStyle = .warning
                errorAlert.messageText = String(
                    localized: "dialog.deleteWorkspaceLayout.failedTitle",
                    defaultValue: "Couldn't Delete Workspace Layout"
                )
                errorAlert.informativeText = error.localizedDescription
                errorAlert.addButton(withTitle: String(
                    localized: "dialog.saveWorkspaceLayout.ok",
                    defaultValue: "OK"
                ))
                errorAlert.beginSheetModal(for: window)
            }
        }
    }

    @objc func saveWorkspaceAsConfigActionMenuItem(_ sender: NSMenuItem) {
        guard let windowId = (sender.representedObject as? NSUUID) as UUID?,
              let context = mainWindowContexts.values.first(where: { $0.windowId == windowId }) else {
            NSSound.beep()
            return
        }
        presentSaveWorkspaceActionDialog(context: context)
    }

    @objc func setNewWorkspaceDefaultLayoutMenuItem(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? WorkspaceDefaultLayoutBox,
              let context = mainWindowContexts.values.first(where: { $0.windowId == box.windowId }),
              let cmuxConfigStore = context.cmuxConfigStore,
              let window = resolvedWindow(for: context) else {
            NSSound.beep()
            return
        }
        do {
            try CmuxConfigActionSaver.setNewWorkspaceDefaultAction(
                id: box.actionID,
                globalConfigPath: cmuxConfigStore.globalConfigPath
            )
            cmuxConfigStore.loadAll()
#if DEBUG
            cmuxDebugLog("newWorkspaceDefaultLayout.updated id=\(box.actionID ?? "<none>")")
#endif
        } catch {
            presentNewWorkspaceDefaultLayoutError(error, for: window)
        }
    }

    private func presentSaveWorkspaceActionDialog(context: MainWindowContext) {
        guard let cmuxConfigStore = context.cmuxConfigStore,
              let workspace = context.tabManager.selectedWorkspace,
              let window = resolvedWindow(for: context) else {
            NSSound.beep()
            return
        }
        presentSaveWorkspaceActionDialog(
            workspace: workspace,
            cmuxConfigStore: cmuxConfigStore,
            window: window
        )
    }

    private func presentSaveWorkspaceActionDialog(
        workspace: Workspace,
        cmuxConfigStore: CmuxConfigStore,
        window: NSWindow
    ) {
        let snapshot = workspace.captureConfigActionSnapshot()
        let globalConfigPath = cmuxConfigStore.globalConfigPath
        if !snapshot.oversizedCommands.isEmpty {
            presentWorkspaceCommandTooLongAlert(for: window)
            return
        }

        let alert = NSAlert()
        alert.messageText = String(
            localized: "dialog.saveWorkspaceLayout.title",
            defaultValue: "Save Workspace Layout"
        )
        let messageFormat = String(
            localized: "dialog.saveWorkspaceLayout.message",
            defaultValue: "Saves this workspace as a reusable layout in %@. It appears in the new-workspace menu and the Command Palette."
        )
        var message = String(
            format: messageFormat,
            (globalConfigPath as NSString).abbreviatingWithTildeInPath
        )
        if snapshot.skippedPanelCount > 0 {
            let skippedFormat = String(
                localized: "dialog.saveWorkspaceLayout.skippedNote",
                defaultValue: "%lld panels have no layout representation (previews, viewers, …) and will be left out."
            )
            message += "\n\n" + String(format: skippedFormat, Int64(snapshot.skippedPanelCount))
        }
        alert.informativeText = message

        let accessory = WorkspaceActionSaveDialogAccessory(
            snapshot: snapshot,
            initialName: workspace.customTitle
                ?? URL(fileURLWithPath: workspace.currentDirectory).lastPathComponent,
            visibleFrame: window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
        )
        alert.accessoryView = accessory.view
        alert.window.initialFirstResponder = accessory.nameField
        alert.addButton(withTitle: String(
            localized: "dialog.saveWorkspaceLayout.save",
            defaultValue: "Save"
        ))
        alert.addButton(withTitle: String(
            localized: "dialog.saveWorkspaceLayout.cancel",
            defaultValue: "Cancel"
        ))

        alert.beginSheetModal(for: window) { [weak window, weak cmuxConfigStore] response in
            guard response == .alertFirstButtonReturn else { return }
            let typedTitle = accessory.nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = typedTitle.isEmpty
                ? String(localized: "dialog.saveWorkspaceLayout.defaultName", defaultValue: "Workspace")
                : typedTitle
            // The recreated workspace carries the action's name: the captured
            // customTitle would otherwise win in executeWorkspaceCommand and
            // the launched workspace wouldn't match the menu entry.
            var definition = snapshot.definition
            definition.name = title
            do {
                let result = try CmuxConfigActionSaver.saveWorkspaceAction(
                    title: title,
                    definition: definition,
                    globalConfigPath: globalConfigPath,
                    // Reserve every id the active store resolved (including
                    // project-local actions) so the saved global action can't
                    // be shadowed into a no-op.
                    reservedActionIDs: cmuxConfigStore.map { Set($0.actionLookup.keys) } ?? []
                )
                var defaultUpdateError: Error?
                if accessory.makeDefaultCheckbox.state == .on {
                    do {
                        try CmuxConfigActionSaver.setNewWorkspaceDefaultAction(
                            id: result.actionID,
                            globalConfigPath: globalConfigPath
                        )
                    } catch {
                        defaultUpdateError = error
                    }
                }
                // The app's store runs without file watchers; reload explicitly
                // so the saved layout shows up in the menus right away.
                cmuxConfigStore?.loadAll()
                if let defaultUpdateError, let window {
                    self.presentNewWorkspaceDefaultLayoutError(defaultUpdateError, for: window)
                }
#if DEBUG
                cmuxDebugLog("saveWorkspaceAction.saved id=\(result.actionID)")
#endif
            } catch {
                guard let window else { return }
                let errorAlert = NSAlert()
                errorAlert.alertStyle = .warning
                errorAlert.messageText = String(
                    localized: "dialog.saveWorkspaceLayout.failedTitle",
                    defaultValue: "Couldn't Save Workspace Layout"
                )
                errorAlert.informativeText = error.localizedDescription
                errorAlert.addButton(withTitle: String(
                    localized: "dialog.saveWorkspaceLayout.ok",
                    defaultValue: "OK"
                ))
                errorAlert.beginSheetModal(for: window)
            }
        }
    }

    private func presentWorkspaceCommandTooLongAlert(for window: NSWindow) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            localized: "dialog.saveWorkspaceLayout.commandTooLongTitle",
            defaultValue: "Command Too Long to Save"
        )
        let messageFormat = String(
            localized: "dialog.saveWorkspaceLayout.commandTooLongMessage",
            defaultValue: "One or more captured commands are longer than %lld UTF-8 bytes and cannot be replayed reliably from a saved layout. Shorten them before saving."
        )
        alert.informativeText = String(
            format: messageFormat,
            Int64(TerminalForegroundCommandCapture.maxReplayableCommandUTF8Length)
        )
        alert.addButton(withTitle: String(
            localized: "dialog.saveWorkspaceLayout.ok",
            defaultValue: "OK"
        ))
        alert.beginSheetModal(for: window)
    }

    private func presentNewWorkspaceDefaultLayoutError(_ error: Error, for window: NSWindow) {
        let errorAlert = NSAlert()
        errorAlert.alertStyle = .warning
        errorAlert.messageText = String(
            localized: "dialog.newWorkspaceDefault.failedTitle",
            defaultValue: "Couldn't Update Default"
        )
        errorAlert.informativeText = error.localizedDescription
        errorAlert.addButton(withTitle: String(
            localized: "dialog.saveWorkspaceLayout.ok",
            defaultValue: "OK"
        ))
        errorAlert.beginSheetModal(for: window)
    }
}
