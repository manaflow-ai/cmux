import CmuxNextPages
import Foundation
import WebKit

extension AgentPaneSchemeHandler {
    /// The libraries the pane loads: Vega and Vega-Lite for charts in replies. Mermaid is not
    /// served here; the pane draws it through the shared diagram worker.
    nonisolated static let paneLibraries: Set<String> = ["vega.js"]

    /// Whether `url` names a file under the pane's `__lib/`.
    nonisolated static func isLibrary(_ url: URL) -> Bool {
        url.scheme?.lowercased() == AgentPaneSource.bundledScheme && url.host?.lowercased() == AgentPaneSource.bundledHost
            && url.path.hasPrefix("/" + MarkdownPageResource.library + "/")
    }

    /// The library `url` names, read from `folder` (the markdown viewer's bundled libraries), as
    /// the markdown page gets it; nil for another URL or a library the pane does not load.
    @concurrent nonisolated static func library(for url: URL, in folder: URL?) async -> Data? {
        guard let folder, isLibrary(url) else { return nil }
        let name = String(url.path.dropFirst(MarkdownPageResource.library.count + 2))
        guard paneLibraries.contains(name) else { return nil }
        return await MarkdownPageResource.library(name, in: folder)
    }

    /// Answers `task` with the library `url` names; a stopped task is never answered.
    func serveLibrary(url: URL, task: any WKURLSchemeTask) {
        let id = ObjectIdentifier(task)
        active.insert(id)
        let folder = libraries
        // task-owner: one library read per scheme task; a stopped task is never answered
        Task { @MainActor [weak self] in
            let data = await Self.library(for: url, in: folder)
            guard let self, self.active.remove(id) != nil else { return }
            guard let data,
                  let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                                 headerFields: Self.headers(for: URL(fileURLWithPath: url.lastPathComponent), length: data.count))
            else {
                task.didFailWithError(URLError(.fileDoesNotExist))
                return
            }
            task.didReceive(response)
            task.didReceive(data)
            task.didFinish()
        }
    }
}
