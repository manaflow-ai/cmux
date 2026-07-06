import AppKit
import CmuxCommandPalette
import Foundation

extension ContentView {
    func appendSavedLayoutCommandContributions(
        to contributions: inout [CommandPaletteCommandContribution],
        workspaceSubtitle: @escaping (CommandPaletteContextSnapshot) -> String
    ) {
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.layout.saveCurrent",
                title: { _ in String(localized: "command.savedLayout.saveCurrent.title", defaultValue: "Save Layout as Template…") },
                subtitle: workspaceSubtitle,
                keywords: ["save", "layout", "template", "preset", "workspace", "split"],
                dismissOnRun: false,
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
                    keywords: ["new", "open", "layout", "template", "preset", "workspace", "split", layout.name]
                )
            )
        }
    }

    func registerSavedLayoutCommandHandlers(_ registry: inout CommandPaletteHandlerRegistry) {
        registry.register(commandId: "palette.layout.saveCurrent") {
            presentSavedLayoutSavePrompt()
        }
        for layout in savedLayoutsForCommandPalette() {
            registry.register(commandId: savedLayoutOpenCommandID(layout.name)) {
                _ = tabManager.openWorkspace(fromSavedLayout: layout, cwdOverride: nil, focus: true)
            }
        }
    }

    private func presentSavedLayoutSavePrompt() {
        guard let workspace = tabManager.selectedWorkspace else {
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

        guard runCmuxModalAlert(alert) == .alertFirstButtonReturn else { return }
        let name = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            presentSavedLayoutError(
                title: String(localized: "dialog.savedLayout.error.title", defaultValue: "Layout Not Saved"),
                message: String(localized: "dialog.savedLayout.error.blankName", defaultValue: "Enter a name before saving the layout.")
            )
            return
        }

        let store = SavedLayoutStore()
        let overwrite: Bool
        do {
            overwrite = try store.layout(named: name) == nil ? false : confirmSavedLayoutOverwrite(name: name)
        } catch {
            presentSavedLayoutError(title: savedLayoutErrorTitle(), message: savedLayoutErrorMessage(error))
            return
        }
        guard overwrite || (try? store.layout(named: name)) == nil else { return }

        let capture = workspace.captureLayoutDefinition()
        do {
            try store.save(
                CmuxSavedLayout(name: name, description: nil, workspace: capture.workspace),
                overwrite: overwrite
            )
        } catch {
            presentSavedLayoutError(title: savedLayoutErrorTitle(), message: savedLayoutErrorMessage(error))
        }
    }

    private func confirmSavedLayoutOverwrite(name: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "dialog.savedLayout.overwrite.title", defaultValue: "Replace Saved Layout?")
        let format = String(localized: "dialog.savedLayout.overwrite.message", defaultValue: "A layout named “%@” already exists. Replace it?")
        alert.informativeText = String.localizedStringWithFormat(format, name)
        alert.addButton(withTitle: String(localized: "dialog.savedLayout.overwrite.confirm", defaultValue: "Replace"))
        alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))
        return runCmuxModalAlert(alert) == .alertFirstButtonReturn
    }

    private func presentSavedLayoutError(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))
        _ = runCmuxModalAlert(alert)
    }

    private func savedLayoutErrorTitle() -> String {
        String(localized: "dialog.savedLayout.error.title", defaultValue: "Layout Not Saved")
    }

    private func savedLayoutErrorMessage(_ error: Error) -> String {
        if let storeError = error as? SavedLayoutStoreError {
            switch storeError {
            case .blankName:
                return String(localized: "dialog.savedLayout.error.blankName", defaultValue: "Enter a name before saving the layout.")
            case .duplicateName:
                return String(localized: "dialog.savedLayout.error.duplicateName", defaultValue: "A layout with that name already exists.")
            case .notFound:
                return String(localized: "dialog.savedLayout.error.notFound", defaultValue: "That saved layout could not be found.")
            case .corruptFile(let description):
                let format = String(localized: "dialog.savedLayout.error.corruptFile", defaultValue: "layouts.json could not be read: %@")
                return String.localizedStringWithFormat(format, description)
            }
        }
        return error.localizedDescription
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
