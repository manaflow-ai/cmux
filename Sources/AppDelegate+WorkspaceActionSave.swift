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

/// Read-only projection of the live cmux.json action registry for native
/// discovery UI. It deliberately carries only resolved action metadata and
/// effective placements; execution stays on the existing action paths.
struct ActionsAndLaunchersDiscoveryModel: Equatable {
    struct Entry: Equatable {
        let id: String
        let title: String
        let actionType: String
        let sourcePath: String
        let appearsInCommandPalette: Bool
        let isNewWorkspaceDefault: Bool
        let appearsInNewWorkspaceMenu: Bool
        let appearsInSurfaceTabBar: Bool
        let shortcutDisplay: String?

        var detailTokens: [String] {
            var tokens = ["type=\(actionType)"]
            if appearsInCommandPalette {
                tokens.append("palette")
            }
            if isNewWorkspaceDefault {
                tokens.append("ui.newWorkspace.action")
            }
            if appearsInNewWorkspaceMenu {
                tokens.append("ui.newWorkspace.contextMenu")
            }
            if appearsInSurfaceTabBar {
                tokens.append("ui.surfaceTabBar.buttons")
            }
            if let shortcutDisplay {
                tokens.append("shortcut=\(shortcutDisplay)")
            }
            return tokens
        }
    }

    let entries: [Entry]

    static func build(
        actions: [CmuxResolvedConfigAction],
        resolvedNewWorkspaceActionID: String?,
        newWorkspaceMenuActionIDs: Set<String>,
        surfaceTabBarActionIDs: Set<String>
    ) -> ActionsAndLaunchersDiscoveryModel {
        let entries = actions.compactMap { action -> Entry? in
            // Built-ins that only come from cmux itself add noise here. An
            // overridden built-in has a source path and remains discoverable.
            guard let sourcePath = action.actionSourcePath else { return nil }
            let shortcutDisplay = action.shortcut.flatMap { shortcut in
                shortcut.isUnbound ? nil : shortcut.displayString
            }
            return Entry(
                id: action.id,
                title: action.title,
                actionType: actionType(action.action),
                sourcePath: sourcePath,
                appearsInCommandPalette: action.palette,
                isNewWorkspaceDefault: action.id == resolvedNewWorkspaceActionID,
                appearsInNewWorkspaceMenu: newWorkspaceMenuActionIDs.contains(action.id),
                appearsInSurfaceTabBar: surfaceTabBarActionIDs.contains(action.id),
                shortcutDisplay: shortcutDisplay
            )
        }
        .sorted {
            let titleOrder = $0.title.localizedStandardCompare($1.title)
            if titleOrder != .orderedSame {
                return titleOrder == .orderedAscending
            }
            return $0.id.localizedStandardCompare($1.id) == .orderedAscending
        }
        return ActionsAndLaunchersDiscoveryModel(entries: entries)
    }

    var summaryText: String {
        guard !entries.isEmpty else { return "actions: {}" }
        return entries.map { entry in
            let source = (entry.sourcePath as NSString).abbreviatingWithTildeInPath
            return [
                "\(entry.title)  [\(entry.id)]",
                "  " + entry.detailTokens.joined(separator: " · "),
                "  " + source,
            ].joined(separator: "\n")
        }
        .joined(separator: "\n\n")
    }

    private static func actionType(_ action: CmuxSurfaceTabBarButtonAction) -> String {
        switch action {
        case .builtIn:
            return "builtin"
        case .command:
            return "command"
        case .agent:
            return "agent"
        case .workspaceCommand:
            return "workspaceCommand"
        case .workspace:
            return "workspace"
        case .actionReference:
            return "action"
        }
    }
}

extension AppDelegate {
    static var actionsAndLaunchersMenuTitle: String {
        String(
            localized: "debug.titlebarLayoutDebug.actions",
            defaultValue: "Actions"
        ) + " · cmux.json…"
    }

    private static var actionsAndLaunchersDialogTitle: String {
        String(
            localized: "debug.titlebarLayoutDebug.actions",
            defaultValue: "Actions"
        ) + " · cmux.json"
    }

    func presentActionsAndLaunchersCustomization(preferredWindow: NSWindow? = nil) {
        let context = [
            preferredWindow,
            NSApp.keyWindow,
            NSApp.mainWindow,
            shortcutRoutingActiveWindow,
        ]
        .compactMap { $0 }
        .compactMap { contextForMainWindow($0) }
        .first

        let cmuxConfigStore: CmuxConfigStore
        if let activeStore = context?.cmuxConfigStore {
            cmuxConfigStore = activeStore
        } else {
            let globalStore = CmuxConfigStore()
            globalStore.loadAll()
            cmuxConfigStore = globalStore
        }

        let newWorkspaceMenuActionIDs = Set(
            cmuxConfigStore.newWorkspaceContextMenuItems.compactMap { item -> String? in
                guard case .action(let menuAction) = item else { return nil }
                return menuAction.action.id
            }
        )
        let model = ActionsAndLaunchersDiscoveryModel.build(
            actions: cmuxConfigStore.loadedActions,
            resolvedNewWorkspaceActionID: cmuxConfigStore.resolvedNewWorkspaceAction()?.id,
            newWorkspaceMenuActionIDs: newWorkspaceMenuActionIDs,
            surfaceTabBarActionIDs: Set(cmuxConfigStore.surfaceTabBarActionReferenceIDs.values)
        )

        let alert = NSAlert()
        alert.messageText = Self.actionsAndLaunchersDialogTitle
        alert.informativeText = (cmuxConfigStore.globalConfigPath as NSString).abbreviatingWithTildeInPath
        alert.accessoryView = actionsAndLaunchersAccessoryView(
            text: model.summaryText,
            entryCount: model.entries.count
        )
        let openLabel = String(
            localized: "settings.settingsJSON.openButton",
            defaultValue: "Open"
        )
        let globalPath = (cmuxConfigStore.globalConfigPath as NSString).abbreviatingWithTildeInPath
        alert.addButton(withTitle: "\(openLabel) \(globalPath)")
        alert.addButton(withTitle: String(
            localized: "settings.settingsJSON.docsButton",
            defaultValue: "Open Docs"
        ))
        alert.addButton(withTitle: String(
            localized: "common.ok",
            defaultValue: "OK"
        ))

        let presentingWindow = context.flatMap { resolvedWindow(for: $0) } ?? preferredWindow
        if let presentingWindow {
            alert.beginSheetModal(for: presentingWindow) { [weak self] response in
                self?.handleActionsAndLaunchersResponse(response)
            }
        } else {
            handleActionsAndLaunchersResponse(alert.runModal())
        }
    }

    @objc func presentActionsAndLaunchersMenuItem(_ sender: NSMenuItem) {
        let preferredWindow: NSWindow?
        if let windowId = (sender.representedObject as? NSUUID) as UUID?,
           let context = mainWindowContexts.values.first(where: { $0.windowId == windowId }) {
            preferredWindow = resolvedWindow(for: context)
        } else {
            preferredWindow = NSApp.keyWindow ?? NSApp.mainWindow
        }
        presentActionsAndLaunchersCustomization(preferredWindow: preferredWindow)
    }

    private func actionsAndLaunchersAccessoryView(
        text: String,
        entryCount: Int
    ) -> NSView {
        let height = min(CGFloat(360), max(CGFloat(120), CGFloat(max(entryCount, 1)) * 64))
        let size = NSSize(width: 620, height: height)
        let textView = NSTextView(frame: NSRect(origin: .zero, size: size))
        textView.string = text
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: size.width, height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: size.width,
            height: .greatestFiniteMagnitude
        )

        let scrollView = NSScrollView(frame: NSRect(origin: .zero, size: size))
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        scrollView.documentView = textView
        return scrollView
    }

    private func handleActionsAndLaunchersResponse(_ response: NSApplication.ModalResponse) {
        switch response {
        case .alertFirstButtonReturn:
            // Reuse the existing in-cmux config editor path used by Settings'
            // workspace-layout customization.
            openWorkspaceLayoutsCustomization()
        case .alertSecondButtonReturn:
            guard let url = URL(string: "https://cmux.com/docs/custom-commands") else { return }
            NSWorkspace.shared.open(url)
        default:
            break
        }
    }

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
