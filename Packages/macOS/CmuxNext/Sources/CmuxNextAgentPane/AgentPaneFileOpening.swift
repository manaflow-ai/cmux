public import Foundation

/// Why `file.open` does not open a file.
public nonisolated enum AgentPaneFileRefusal: Error, Equatable, Sendable {
    /// A relative path: the CLI sends the path as typed, and the app has no
    /// working directory to resolve it against.
    case relativePath
    /// Not an existing regular file.
    case notAFile
    /// A tab would show it as a page, so it opens in the editor only.
    case notInTab
    /// No app on this Mac edits text.
    case noEditor
}

/// What `file.open` opens (#16723): the checked file, and the editor app when
/// it opens there. The agent pane's changed files, the palette and
/// `cmux file open` all run this one check before anything opens.
public nonisolated struct AgentPaneFileOpening: Equatable, Sendable {
    public let url: URL
    /// The app that opens the file; nil for a tab in the pane.
    public let editor: URL?

    @MainActor public static func plan(
        path: String,
        target: AgentPaneFileTarget,
        editor: @MainActor () -> URL? = { AgentPaneFileOpen.editorApplication() }
    ) throws -> AgentPaneFileOpening {
        guard path.isEmpty || path.hasPrefix("/") else { throw AgentPaneFileRefusal.relativePath }
        guard let url = AgentPaneFileOpen.resolve(path) else { throw AgentPaneFileRefusal.notAFile }
        switch target {
        case .tab:
            guard AgentPaneFileOpen.showsInTab(url) else { throw AgentPaneFileRefusal.notInTab }
            return AgentPaneFileOpening(url: url, editor: nil)
        case .editor:
            guard let app = editor() else { throw AgentPaneFileRefusal.noEditor }
            return AgentPaneFileOpening(url: url, editor: app)
        }
    }
}
