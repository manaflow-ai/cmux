import AppKit
import CmuxCommandPalette
import Foundation

extension ContentView {
    static func savedLayoutPresentingWindow(
        for context: CommandPaletteActionContext,
        appDelegate: AppDelegate?
    ) -> NSWindow? {
        guard context.target.windowID == context.owningWindowID,
              let appDelegate,
              let liveContext = appDelegate.liveMainWindowContextForAction(
                  tabManager: context.tabManager
              ),
              liveContext.windowId == context.target.windowID else {
            return nil
        }
        return appDelegate.mainWindow(for: context.target.windowID)
    }

    static func shouldHandleSavedLayoutSaveRequest(
        observedWindow: NSWindow?,
        requestedWindow: NSWindow?,
        keyWindow: NSWindow?,
        mainWindow: NSWindow?
    ) -> Bool {
        shouldHandleCommandPaletteRequest(
            observedWindow: observedWindow,
            requestedWindow: requestedWindow,
            keyWindow: keyWindow,
            mainWindow: mainWindow
        )
    }

    func appendSavedLayoutCommandContributions(
        to contributions: inout [CommandPaletteCommandContribution],
        workspaceSubtitle: @escaping (CommandPaletteContextSnapshot) -> String
    ) {
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.layout.saveCurrent",
                title: { _ in String(localized: "command.savedLayout.saveCurrent.title", defaultValue: "Save Layout as Template…") },
                subtitle: workspaceSubtitle,
                shortcutHint: KeyboardShortcutSettings.shortcutIfBound(for: .saveLayoutTemplate)?.displayString,
                keywords: ["save", "layout", "template", "preset", "workspace", "split"],
                arguments: [
                    CmuxActionArgumentDefinition(name: "name"),
                    CmuxActionArgumentDefinition(
                        name: "overwrite",
                        valueType: .boolean,
                        required: false
                    ),
                ],
                when: { $0.bool(CommandPaletteContextKeys.hasWorkspace) },
                enablement: { $0.bool(CommandPaletteContextKeys.hasWorkspace) }
            )
        )
        for layout in savedLayoutsForCommandPalette() {
            let format = String(localized: "command.savedLayout.openNamed.title", defaultValue: "New Workspace from Layout: %@")
            contributions.append(
                CommandPaletteCommandContribution(
                    commandId: savedLayoutOpenCommandID(layout.name),
                    title: { _ in String.localizedStringWithFormat(format, layout.name) },
                    subtitle: { _ in String(localized: "command.savedLayout.subtitle", defaultValue: "Saved Layouts") },
                    keywords: ["new", "open", "layout", "template", "preset", "workspace", "split", layout.name],
                    arguments: Self.commandPaletteOptionalFocusArguments
                )
            )
        }
    }

    func registerSavedLayoutCommandHandlers(
        _ registry: inout CommandPaletteHandlerRegistry,
        context: CommandPaletteActionContext
    ) {
        registry.register(commandId: "palette.layout.saveCurrent") { invocation in
            guard let workspaceID = context.workspace()?.id else {
                return .targetUnavailable
            }
            if let name = invocation.string("name") {
                do {
                    try saveCurrentLayout(
                        named: name,
                        overwrite: invocation.bool("overwrite") ?? false,
                        workspaceID: workspaceID,
                        focusedPanelID: context.target.panelID
                    )
                    return .completed
                } catch {
                    return .failed(
                        code: savedLayoutActionErrorCode(error),
                        message: savedLayoutErrorMessage(error)
                    )
                }
            }
            guard context.target.panelID == nil || context.panel() != nil,
                  let presentingWindow = Self.savedLayoutPresentingWindow(
                      for: context,
                      appDelegate: AppDelegate.shared
                  ) else {
                return .targetUnavailable
            }
            presentSavedLayoutSavePrompt(
                workspaceID: workspaceID,
                focusedPanelID: context.target.panelID,
                presentingWindow: presentingWindow
            )
            return .presented
        }
        for layout in savedLayoutsForCommandPalette() {
            let layoutName = layout.name
            registry.register(commandId: savedLayoutOpenCommandID(layoutName)) { invocation in
                guard context.target.workspaceID == nil || context.workspace() != nil else {
                    return .targetUnavailable
                }
                do {
                    guard let resolvedLayout = try SavedLayoutStore().layout(named: layoutName) else {
                        throw SavedLayoutStoreError.notFound(layoutName)
                    }
                    guard context.tabManager.openWorkspace(
                        fromSavedLayout: resolvedLayout,
                        cwdOverride: nil,
                        focus: Self.commandPaletteShouldFocus(
                            invocation,
                            interactiveDefault: true
                        ),
                        sourceWorkspaceID: context.workspace()?.id
                    ) != nil else {
                        return .failed(
                            code: "action_failed",
                            message: savedLayoutErrorMessage(SavedLayoutActionError.targetUnavailable)
                        )
                    }
                    return .completed
                } catch {
                    return .failed(
                        code: savedLayoutActionErrorCode(error),
                        message: savedLayoutErrorMessage(error)
                    )
                }
            }
        }
    }

    func presentSavedLayoutSavePrompt(
        workspaceID requestedWorkspaceID: UUID? = nil,
        focusedPanelID requestedFocusedPanelID: UUID? = nil,
        presentingWindow: NSWindow? = nil
    ) {
        let resolvedPresentingWindow = presentingWindow ?? commandPaletteTargetWindow
        guard let workspaceID = requestedWorkspaceID ?? tabManager.selectedWorkspace?.id,
              let workspace = tabManager.tabs.first(where: { $0.id == workspaceID }) else {
            NSSound.beep()
            return
        }
        let focusedPanelID = requestedFocusedPanelID ?? workspace.focusedPanelId
        if let requestedFocusedPanelID,
           workspace.panels[requestedFocusedPanelID] == nil {
            NSSound.beep()
            return
        }

        let alert = NSAlert()
        alert.messageText = String(localized: "dialog.savedLayout.save.title", defaultValue: "Save Layout as Template")
        alert.informativeText = String(localized: "dialog.savedLayout.save.message", defaultValue: "Enter a name for this workspace layout.")
        alert.addButton(withTitle: String(localized: "dialog.savedLayout.save.confirm", defaultValue: "Save"))
        alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        input.placeholderString = String(localized: "dialog.savedLayout.save.placeholder", defaultValue: "Layout name")
        alert.accessoryView = input
        alert.window.initialFirstResponder = input

        guard alert.runCmuxModal(presentingWindow: resolvedPresentingWindow) == .alertFirstButtonReturn else {
            return
        }
        let name = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            presentSavedLayoutError(
                title: String(localized: "dialog.savedLayout.error.title", defaultValue: "Layout Not Saved"),
                message: String(localized: "dialog.savedLayout.error.blankName", defaultValue: "Enter a name before saving the layout."),
                presentingWindow: resolvedPresentingWindow
            )
            return
        }

        let store = SavedLayoutStore()
        let overwrite: Bool
        do {
            overwrite = try store.layout(named: name) == nil
                ? false
                : confirmSavedLayoutOverwrite(name: name, presentingWindow: resolvedPresentingWindow)
        } catch {
            presentSavedLayoutError(
                title: savedLayoutErrorTitle(),
                message: savedLayoutErrorMessage(error),
                presentingWindow: resolvedPresentingWindow
            )
            return
        }
        guard overwrite || (try? store.layout(named: name)) == nil else { return }

        do {
            try saveCurrentLayout(
                named: name,
                overwrite: overwrite,
                workspaceID: workspaceID,
                focusedPanelID: focusedPanelID
            )
        } catch {
            presentSavedLayoutError(
                title: savedLayoutErrorTitle(),
                message: savedLayoutErrorMessage(error),
                presentingWindow: resolvedPresentingWindow
            )
        }
    }

    private func saveCurrentLayout(
        named rawName: String,
        overwrite: Bool,
        workspaceID: UUID,
        focusedPanelID: UUID?
    ) throws {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw SavedLayoutStoreError.blankName }
        guard let workspace = tabManager.tabs.first(where: { $0.id == workspaceID }) else {
            throw SavedLayoutActionError.targetUnavailable
        }
        if let focusedPanelID, workspace.panels[focusedPanelID] == nil {
            throw SavedLayoutActionError.targetUnavailable
        }
        let capture = try workspace.captureLayoutDefinition(focusedPanelID: focusedPanelID)
        try SavedLayoutStore().save(
            CmuxSavedLayout(name: name, description: nil, workspace: capture.workspace),
            overwrite: overwrite
        )
    }

    private func savedLayoutActionErrorCode(_ error: Error) -> String {
        if let storeError = error as? SavedLayoutStoreError {
            switch storeError {
            case .blankName:
                return "invalid_argument"
            case .duplicateName:
                return "already_exists"
            case .notFound:
                return "not_found"
            case .corruptFile:
                return "invalid_state"
            }
        }
        if error is SavedLayoutActionError ||
            (error as? SavedLayoutCaptureError) == .targetPanelUnavailable {
            return "target_unavailable"
        }
        return "internal_error"
    }

    private func confirmSavedLayoutOverwrite(
        name: String,
        presentingWindow: NSWindow?
    ) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "dialog.savedLayout.overwrite.title", defaultValue: "Replace Saved Layout?")
        let format = String(localized: "dialog.savedLayout.overwrite.message", defaultValue: "A layout named “%@” already exists. Replace it?")
        alert.informativeText = String.localizedStringWithFormat(format, name)
        alert.addButton(withTitle: String(localized: "dialog.savedLayout.overwrite.confirm", defaultValue: "Replace"))
        alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))
        return alert.runCmuxModal(presentingWindow: presentingWindow) == .alertFirstButtonReturn
    }

    private func presentSavedLayoutError(
        title: String,
        message: String,
        presentingWindow: NSWindow?
    ) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))
        _ = alert.runCmuxModal(presentingWindow: presentingWindow)
    }

    private func savedLayoutErrorTitle() -> String {
        String(localized: "dialog.savedLayout.error.title", defaultValue: "Layout Not Saved")
    }

    private func savedLayoutErrorMessage(_ error: Error) -> String {
        if error is SavedLayoutActionError ||
            (error as? SavedLayoutCaptureError) == .targetPanelUnavailable {
            return String(
                localized: "action.error.targetUnavailable",
                defaultValue: "The action target is no longer available."
            )
        }
        if let storeError = error as? SavedLayoutStoreError {
            switch storeError {
            case .blankName:
                return String(localized: "dialog.savedLayout.error.blankName", defaultValue: "Enter a name before saving the layout.")
            case .duplicateName:
                return String(localized: "dialog.savedLayout.error.duplicateName", defaultValue: "A layout with that name already exists.")
            case .notFound:
                return String(localized: "dialog.savedLayout.error.notFound", defaultValue: "That saved layout could not be found.")
            case .corruptFile:
                return String(localized: "dialog.savedLayout.error.corruptFile", defaultValue: "The saved layouts file could not be read. Check it and try again.")
            }
        }
        return String(localized: "dialog.savedLayout.error.unknown", defaultValue: "The saved layout request could not be completed. Try again.")
    }

    private func savedLayoutsForCommandPalette() -> [CmuxSavedLayout] {
        (try? SavedLayoutStore().list()) ?? []
    }

    private func savedLayoutOpenCommandID(_ name: String) -> String {
        let encodedName = Data(name.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        return "palette.layout.open.\(encodedName)"
    }
}

extension Notification.Name {
    static let savedLayoutSaveRequested = Notification.Name("cmux.savedLayoutSaveRequested")
}
