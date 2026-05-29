import AppKit
import SwiftUI
import Observation
import Darwin
import Bonsplit
import UniformTypeIdentifiers

func openCmuxSettingsFileInEditor() {
    let url = KeyboardShortcutSettings.settingsFileStore.settingsFileURLForEditing()
    PreferredEditorSettings.open(url)
}
