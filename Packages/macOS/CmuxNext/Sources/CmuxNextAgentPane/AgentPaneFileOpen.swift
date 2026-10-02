public import AppKit
public import Foundation
import UniformTypeIdentifiers

/// Where the page asks to open a file: a tab beside the agent, or the editor.
public nonisolated enum AgentPaneFileTarget: String, Equatable, Sendable {
    case tab
    case editor
}

/// Opening a file the page names. The path comes from an agent's tool calls,
/// so the host opens only an existing regular file, and never with the file's
/// own handler: a tab shows it as a page, and the editor is the app for source
/// code or plain text, so a script or an app bundle is never run.
public nonisolated enum AgentPaneFileOpen {
    /// The file at `path`, or nil unless `path` is absolute and names an
    /// existing regular file (after links), not a folder or a package.
    public static func resolve(_ path: String, fileManager: FileManager = .default) -> URL? {
        guard path.hasPrefix("/"), !path.contains("\u{0}") else { return nil }
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue,
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isPackageKey]),
              values.isRegularFile == true, values.isPackage != true else { return nil }
        return url
    }

    /// The app that edits text: the default for source code, else for plain text.
    @MainActor public static func editorApplication(workspace: NSWorkspace = .shared) -> URL? {
        workspace.urlForApplication(toOpen: .sourceCode) ?? workspace.urlForApplication(toOpen: .plainText)
    }
}
