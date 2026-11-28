package import AppKit

/// A file panel for a terminal's file commands (TextBox's Add Files, Insert Path): files and
/// folders, several at once, as a sheet on the terminal's window, and the text that types the
/// chosen paths as a drop of those files does.
package struct TerminalFilePicker {
    package init() {}
    /// The paths the person chose in `panel`, configured here; empty on Cancel. A window that
    /// already shows a sheet gets the panel as its own window.
    package static func choose(_ panel: NSOpenPanel, title: String? = nil, prompt: String, in window: NSWindow?) async -> [String] {
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = []
        if let title { panel.title = title }
        panel.prompt = prompt
        let response = await withCheckedContinuation { done in
            if let window, window.attachedSheet == nil {
                panel.beginSheetModal(for: window) { done.resume(returning: $0) }
            } else {
                panel.begin { done.resume(returning: $0) }
            }
        }
        return response == .OK ? panel.urls.map(\.path) : []
    }

    /// The text Insert Path types for `paths`: each shell-escaped as a dropped file is, joined by
    /// a space, no trailing space. Nil for no paths.
    package static func insertText(for paths: [String]) -> String? {
        paths.isEmpty ? nil : paths.map(TerminalPasteboard.shellEscaped).joined(separator: " ")
    }
}
