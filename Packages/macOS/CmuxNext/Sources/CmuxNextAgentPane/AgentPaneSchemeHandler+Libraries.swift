import CmuxNextCompat
import CmuxNextPages
import Foundation
import WebKit

extension AgentPaneSchemeHandler {
    /// The libraries the pane loads: Vega and Vega-Lite for charts in replies, Ondine (Mermaid
    /// compiled to WebAssembly) for diagrams, and Mermaid 11 as Ondine's fallback.
    nonisolated static let paneLibraries: Set<String> = ["vega.js", "ondine.js", "mermaid.js"]

    /// Whether `url` names a file under the pane's `__lib/`.
    nonisolated static func isLibrary(_ url: URL) -> Bool {
        url.scheme?.lowercased() == AgentPaneSource.bundledScheme && url.host?.lowercased() == AgentPaneSource.bundledHost
            && url.path.hasPrefix("/" + MarkdownPageResource.library + "/")
    }

    /// The library `url` names, read from `folder` (the markdown viewer's bundled libraries) on `runner`'s
    /// files lane, as the markdown page gets it; nil for another URL or a library the pane does not load.
    nonisolated static func library(for url: URL, in folder: URL?, runner: any MayBlockRunner) async -> Data? {
        guard let folder, isLibrary(url) else { return nil }
        let name = String(url.path.dropFirst(MarkdownPageResource.library.count + 2))
        guard paneLibraries.contains(name) else { return nil }
        return await MarkdownPageResource.library(name, in: folder, runner: runner)
    }

    /// Answers `task` with the library `url` names; a stopped task is never answered.
    func serveLibrary(url: URL, task: any WKURLSchemeTask) {
        let id = ObjectIdentifier(task)
        active.insert(id)
        let folder = libraries, runner = runner
        // task-owner: one library read per scheme task; a stopped task is never answered
        Task { @MainActor [weak self] in
            let data = await Self.library(for: url, in: folder, runner: runner)
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
