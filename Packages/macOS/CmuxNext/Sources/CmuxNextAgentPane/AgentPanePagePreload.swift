import CmuxNextCompat
import Foundation

/// The bundled page's first files, read at the top of launch on the warm-up
/// thread (cx-z9kz0). A scheme request reaches the main thread, and a read
/// answered after it needed a second main-thread turn: during launch the
/// page's first request waited about 55 ms for it. A preloaded file is
/// answered in the request's own callback, once; later pages read again.
public nonisolated enum AgentPanePagePreload {
    /// The files the page asks for before it mounts.
    static let names = ["index.html", "pane.js", "locales/loader.js"]
    private static let files = Mutex<[String: Data]>([:])

    /// Reads the files on the calling thread (never the main thread).
    public static func start() {
        guard let page = Bundle.module.url(forResource: "index", withExtension: "html", subdirectory: "agent-pane") else { return }
        let root = page.deletingLastPathComponent()
        for name in names {
            guard let url = URL(string: "\(AgentPaneSource.bundledOrigin)/\(name)"),
                  let file = AgentPaneSchemeHandler.fileURL(for: url, root: root),
                  // concurrency-allow: the launch warm-up thread, never the main thread
                  let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { continue }
            files.withLock { $0[file.path] = data }
        }
    }

    /// `file`'s preloaded bytes, the first time it is asked for.
    static func take(_ file: URL) -> Data? {
        files.withLock { $0.removeValue(forKey: file.path) }
    }
}
