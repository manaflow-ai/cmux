import AppKit
import Foundation

// MARK: - Save Workspace as Action (new-workspace plus-button menu)

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

extension AppDelegate {

    /// Appends the always-available "Save Workspace as Action…",
    /// "Delete Action" (when something is deletable), and
    /// "Customize Actions…" items to the new-workspace plus-button menu.
    func appendWorkspaceActionAffordances(
        to menu: NSMenu,
        windowId: UUID,
        cmuxConfigStore: CmuxConfigStore
    ) {
        if !menu.items.isEmpty {
            menu.addItem(.separator())
        }
        let saveItem = NSMenuItem(
            title: String(
                localized: "menu.newWorkspace.saveWorkspaceAsAction",
                defaultValue: "Save Workspace as Action…"
            ),
            action: #selector(saveWorkspaceAsConfigActionMenuItem(_:)),
            keyEquivalent: ""
        )
        saveItem.target = self
        saveItem.representedObject = windowId as NSUUID
        menu.addItem(saveItem)

        let deletableActions = cmuxConfigStore.loadedActions
            .filter { isDeletableGlobalAction($0, cmuxConfigStore: cmuxConfigStore) }
            .sorted { ($0.title, $0.id) < ($1.title, $1.id) }
        if !deletableActions.isEmpty {
            let deleteParent = NSMenuItem(
                title: String(
                    localized: "menu.newWorkspace.deleteActionSubmenu",
                    defaultValue: "Delete Action"
                ),
                action: nil,
                keyEquivalent: ""
            )
            let submenu = NSMenu()
            for action in deletableActions {
                let item = NSMenuItem(
                    title: action.title,
                    action: #selector(deleteWorkspaceConfigActionMenuItem(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = WorkspaceActionDeleteBox(
                    windowId: windowId,
                    actionID: action.id,
                    actionTitle: action.title
                )
                item.image = action.icon?.contextMenuImage(
                    configSourcePath: action.iconSourcePath,
                    globalConfigPath: cmuxConfigStore.globalConfigPath
                )
                submenu.addItem(item)
            }
            deleteParent.submenu = submenu
            menu.addItem(deleteParent)
        }

        let customizeItem = NSMenuItem(
            title: String(
                localized: "menu.newWorkspace.customizeActions",
                defaultValue: "Customize Actions…"
            ),
            action: #selector(customizeCmuxConfigActionsMenuItem(_:)),
            keyEquivalent: ""
        )
        customizeItem.target = self
        customizeItem.representedObject = windowId as NSUUID
        menu.addItem(customizeItem)
    }

    /// Actions defined in the global config (where "Save Workspace as Action"
    /// writes) are deletable from the UI; project-local and built-in actions
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
            localized: "dialog.deleteWorkspaceAction.title",
            defaultValue: "Delete Action?"
        )
        let messageFormat = String(
            localized: "dialog.deleteWorkspaceAction.message",
            defaultValue: "Removes “%1$@” from %2$@. Workspaces it already created stay open."
        )
        alert.informativeText = String(
            format: messageFormat,
            box.actionTitle,
            (cmuxConfigStore.globalConfigPath as NSString).abbreviatingWithTildeInPath
        )
        let deleteButton = alert.addButton(withTitle: String(
            localized: "dialog.deleteWorkspaceAction.delete",
            defaultValue: "Delete"
        ))
        deleteButton.hasDestructiveAction = true
        alert.addButton(withTitle: String(
            localized: "dialog.deleteWorkspaceAction.cancel",
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
                    localized: "dialog.deleteWorkspaceAction.failedTitle",
                    defaultValue: "Couldn't Delete Action"
                )
                errorAlert.informativeText = error.localizedDescription
                errorAlert.addButton(withTitle: String(
                    localized: "dialog.saveWorkspaceAction.ok",
                    defaultValue: "OK"
                ))
                errorAlert.beginSheetModal(for: window)
            }
        }
    }

    @objc private func saveWorkspaceAsConfigActionMenuItem(_ sender: NSMenuItem) {
        guard let windowId = (sender.representedObject as? NSUUID) as UUID?,
              let context = mainWindowContexts.values.first(where: { $0.windowId == windowId }) else {
            NSSound.beep()
            return
        }
        presentSaveWorkspaceActionDialog(context: context)
    }

    @objc private func customizeCmuxConfigActionsMenuItem(_ sender: NSMenuItem) {
        // Open inside cmux's own file editor rather than an external app — the
        // OS-default handler for .json can be Xcode, which is never what
        // "customize my actions" means.
        let configURL = SidebarWorkspaceGroupConfigOpener.materializedCmuxConfigURL()
        guard let windowId = (sender.representedObject as? NSUUID) as UUID?,
              let context = mainWindowContexts.values.first(where: { $0.windowId == windowId }),
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

        let alert = NSAlert()
        alert.messageText = String(
            localized: "dialog.saveWorkspaceAction.title",
            defaultValue: "Save Workspace as Action"
        )
        let messageFormat = String(
            localized: "dialog.saveWorkspaceAction.message",
            defaultValue: "Saves this workspace's layout as a reusable action in %@. It appears in the new-workspace menu and the Command Palette."
        )
        var message = String(
            format: messageFormat,
            (globalConfigPath as NSString).abbreviatingWithTildeInPath
        )
        if snapshot.skippedPanelCount > 0 {
            let skippedFormat = String(
                localized: "dialog.saveWorkspaceAction.skippedNote",
                defaultValue: "%lld panels have no layout representation (previews, viewers, …) and will be left out."
            )
            message += "\n\n" + String(format: skippedFormat, Int64(snapshot.skippedPanelCount))
        }
        let capturedCommands = snapshot.capturedCommands
        if !capturedCommands.isEmpty {
            // Show every command verbatim so nothing secret-bearing is written
            // to the config without the user seeing it first.
            let commandsHeader = String(
                localized: "dialog.saveWorkspaceAction.commandsHeader",
                defaultValue: "Commands that will be saved and re-run:"
            )
            message += "\n\n" + commandsHeader + "\n" + capturedCommands.joined(separator: "\n")
        }
        let capturedURLs = snapshot.capturedURLs
        if !capturedURLs.isEmpty {
            let urlsHeader = String(
                localized: "dialog.saveWorkspaceAction.urlsHeader",
                defaultValue: "URLs that will be saved:"
            )
            message += "\n\n" + urlsHeader + "\n" + capturedURLs.joined(separator: "\n")
        }
        let capturedEnvironmentKeys = snapshot.capturedEnvironmentKeys
        if !capturedEnvironmentKeys.isEmpty {
            let envHeader = String(
                localized: "dialog.saveWorkspaceAction.envHeader",
                defaultValue: "Environment variables whose values will be saved:"
            )
            message += "\n\n" + envHeader + "\n" + capturedEnvironmentKeys.joined(separator: ", ")
        }
        alert.informativeText = message

        let nameField = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        nameField.stringValue = workspace.customTitle
            ?? URL(fileURLWithPath: workspace.currentDirectory).lastPathComponent
        nameField.placeholderString = String(
            localized: "dialog.saveWorkspaceAction.namePlaceholder",
            defaultValue: "Action name"
        )
        alert.accessoryView = nameField
        alert.window.initialFirstResponder = nameField
        alert.addButton(withTitle: String(
            localized: "dialog.saveWorkspaceAction.save",
            defaultValue: "Save"
        ))
        alert.addButton(withTitle: String(
            localized: "dialog.saveWorkspaceAction.cancel",
            defaultValue: "Cancel"
        ))

        alert.beginSheetModal(for: window) { [weak window, weak cmuxConfigStore] response in
            guard response == .alertFirstButtonReturn else { return }
            let typedTitle = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = typedTitle.isEmpty
                ? String(localized: "dialog.saveWorkspaceAction.defaultName", defaultValue: "Workspace")
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
                // The app's store runs without file watchers; reload explicitly
                // so the saved action shows up in the menus right away.
                cmuxConfigStore?.loadAll()
#if DEBUG
                cmuxDebugLog("saveWorkspaceAction.saved id=\(result.actionID)")
#endif
            } catch {
                guard let window else { return }
                let errorAlert = NSAlert()
                errorAlert.alertStyle = .warning
                errorAlert.messageText = String(
                    localized: "dialog.saveWorkspaceAction.failedTitle",
                    defaultValue: "Couldn't Save Action"
                )
                errorAlert.informativeText = error.localizedDescription
                errorAlert.addButton(withTitle: String(
                    localized: "dialog.saveWorkspaceAction.ok",
                    defaultValue: "OK"
                ))
                errorAlert.beginSheetModal(for: window)
            }
        }
    }
}
