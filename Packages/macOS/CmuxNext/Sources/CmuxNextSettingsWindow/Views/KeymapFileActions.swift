import AppKit
import CmuxNextDesign
import CmuxNextSettings
import SwiftUI
import UniformTypeIdentifiers

/// Imports and exports the next keymap without bypassing the config actor.
/// The panels are deliberately small and live above the searchable action
/// list so the operation remains discoverable when a query hides every row.
struct KeymapFileActions: View {
    let model: SettingsWindowModel

    var body: some View {
        HStack(spacing: Metrics.space3) {
            Button(SettingsWindowStrings.keymapImport) { importKeymap() }
                .buttonStyle(SettingsButtonStyle())
                .accessibilityIdentifier("cmux.settings.keymap.import")
            Button(SettingsWindowStrings.keymapExport) { exportKeymap() }
                .buttonStyle(SettingsButtonStyle())
                .accessibilityIdentifier("cmux.settings.keymap.export")
            Spacer(minLength: 0)
        }
    }

    private func exportKeymap() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "cmux-next-keymap.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let value = try await model.settings.shortcutKeymap()
                try Data(value.prettyText().utf8).write(to: url, options: .atomic)
                model.writeError = nil
            } catch {
                model.writeError = SettingsWindowStrings.writeFailed(String(describing: error))
            }
        }
    }

    private func importKeymap() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let source = try String(contentsOf: url, encoding: .utf8)
                let value = try JSONC.parse(source)
                try await model.settings.importShortcutKeymap(value)
                await model.settings.reload()
                model.writeError = nil
            } catch {
                model.writeError = SettingsWindowStrings.writeFailed(String(describing: error))
            }
        }
    }
}
