public import AppKit
public import Foundation

/// Where the page asks to open a file: a tab beside the agent, or the editor.
public nonisolated enum AgentPaneFileTarget: String, Equatable, Sendable {
    case tab
    case editor
}

/// Opening a file the page names.
public nonisolated enum AgentPaneFileOpen {
    /// The file at `path` the host may open.
    public static func resolve(_ path: String, fileManager: FileManager = .default) -> URL? {
        nil
    }

    /// The app that opens a file in the editor.
    @MainActor public static func editorApplication(workspace: NSWorkspace = .shared) -> URL? {
        nil
    }
}
