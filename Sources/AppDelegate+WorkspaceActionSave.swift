import AppKit
import Foundation

// MARK: - Save Workspace as Action (new-workspace plus-button menu)

extension AppDelegate {

    /// Appends the always-available "Save Workspace as Action…" and
    /// "Customize Actions…" items to the new-workspace plus-button menu.
    func appendWorkspaceActionAffordances(to menu: NSMenu, windowId: UUID) {
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
        // Capture reads the live agent index; refresh it first so running
        // agents aren't silently dropped from the saved action when the
        // cache is cold or stale.
        Task { @MainActor [weak self, weak workspace, weak window, weak cmuxConfigStore] in
            await SharedLiveAgentIndex.shared.waitForFreshIndex()
            guard let self, let workspace, let window, let cmuxConfigStore else { return }
            self.presentSaveWorkspaceActionDialog(
                workspace: workspace,
                cmuxConfigStore: cmuxConfigStore,
                window: window
            )
        }
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
            do {
                let result = try CmuxConfigActionSaver.saveWorkspaceAction(
                    title: title,
                    definition: snapshot.definition,
                    globalConfigPath: globalConfigPath
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
