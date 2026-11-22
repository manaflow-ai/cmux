public import AppKit
public import Foundation
import CmuxNextPages
import CmuxNextWindowRules

/// The app `file.open {where: editor}` opens a file with (#16723): this Mac's text editor, and the
/// open itself. The App holds one; tests pass a fake that records the open.
@MainActor public protocol AgentPaneEditorApps: AnyObject {
    /// The app that edits source code or plain text on this Mac; nil when none does.
    func application() -> URL?
    /// Opens `url` with `app`.
    func open(_ url: URL, withApplicationAt app: URL)
}

extension AgentPaneEditorApps {
    public func open(_ opening: AgentPaneFileOpening, line: Int?) {
        guard let editor = opening.editor else { return }
        let location = WindowRules.editorLocation(for: opening.url, line: line, bundleID: Bundle(url: editor)?.bundleIdentifier)
        open(location, withApplicationAt: editor)
    }
}

/// This Mac's editors, through `NSWorkspace`.
@MainActor public final class AgentPaneWorkspaceEditors: AgentPaneEditorApps {
    private let workspace: NSWorkspace

    /// The editors `workspace` knows.
    public init(workspace: NSWorkspace = .shared) {
        self.workspace = workspace
    }

    public func application() -> URL? {
        LinkMenu().editor(workspace: workspace)
    }

    public func open(_ url: URL, withApplicationAt app: URL) {
        workspace.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }
}
