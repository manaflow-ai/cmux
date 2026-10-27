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
}

/// What `file.open` opens (#16723): the checked file. The agent pane's changed files, the palette and
/// `cmux file open` all run this one check before anything opens; the editor app that opens it there is
/// Launch Services' answer, which the App reads off the main thread.
public nonisolated struct AgentPaneFileOpening: Equatable, Sendable {
    public let url: URL

    @MainActor public static func plan(path: String, target: AgentPaneFileTarget) throws -> AgentPaneFileOpening {
        guard path.isEmpty || path.hasPrefix("/") else { throw AgentPaneFileRefusal.relativePath }
        guard let url = AgentPaneFileOpen.resolve(path) else { throw AgentPaneFileRefusal.notAFile }
        if target == .tab, !AgentPaneFileOpen.showsInTab(url) { throw AgentPaneFileRefusal.notInTab }
        return AgentPaneFileOpening(url: url)
    }
}
