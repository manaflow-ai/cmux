import CmuxNextCompat
import Foundation

/// The bundled agent page's first files (`index.html`, its strings, `pane.js` and the chunks it
/// imports), read off the main thread at the top of launch (bd cx-z9kz0). The scheme handler
/// answers a cached file in the turn its request arrives: a file read off the main thread came
/// back on a later main turn, and at launch each such turn waited behind the windows being built
/// (four files in a row: the page, its strings loader, its strings, its script).
///
/// Kept for the run: every agent page loads the same files. Copies, not mapped files, so an app
/// update that rewrites the bundle in place cannot fault a later page's read.
nonisolated enum AgentPanePageFiles {
    private static let files = Mutex<[String: Data]>([:])

    /// The cached contents of `file` (a path `AgentPaneSchemeHandler.fileURL` resolved).
    static func cached(_ file: URL) -> Data? {
        files.withLock { $0[file.path] }
    }

    /// Reads the first files of the page in `root` off the main thread.
    @MainActor static func prefetch(root: URL) {
        // task-owner: one bounded read of the page's first files at launch; nothing waits on it
        Task { await read(root: root.standardizedFileURL.resolvingSymlinksInPath()) }
    }

    @concurrent private static func read(root: URL) async {
        let language = Locale.preferredLanguages.first?.split(separator: "-").first.map(String.init) ?? "en"
        let locales = root.appendingPathComponent("locales")
        let strings = ((try? FileManager.default.contentsOfDirectory(atPath: locales.path)) ?? [])
            .filter { $0 == "loader.js" || $0 == "en.js" || $0.hasPrefix(language) }
            .map { "locales/\($0)" }
        var pending = ["index.html", "pane.js"] + strings
        var seen = Set(pending)
        while !pending.isEmpty {
            let name = pending.removeFirst() // in request order: the page first
            let file = root.appendingPathComponent(name).standardizedFileURL.resolvingSymlinksInPath()
            // concurrency-allow: @concurrent, so this read never runs on the main actor
            guard file.path.hasPrefix(root.path + "/"), let data = try? Data(contentsOf: file) else { continue }
            files.withLock { $0[file.path] = data }
            // A script's static imports load before it runs; its dynamic ones (`import(...)`) when used.
            guard name.hasSuffix(".js"), let text = String(data: data, encoding: .utf8) else { continue }
            let directory = (name as NSString).deletingLastPathComponent
            for imported in staticImports(in: text) {
                let path = ((directory as NSString).appendingPathComponent(imported) as NSString).standardizingPath
                if seen.insert(path).inserted { pending.append(path) }
            }
        }
    }

    /// The relative paths `script` imports statically (`import … from "./x.js"`, `export … from`).
    static func staticImports(in script: String) -> [String] {
        script.matches(of: /from\s*["'](\.{1,2}\/[^"']+\.js)["']/).map { String($0.1) }
    }
}
