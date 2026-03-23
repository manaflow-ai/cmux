import Foundation

/// Downloads and caches Monaco Editor files locally so editor panels load instantly.
/// Call `MonacoCache.prefetch()` at app startup. Editor HTML loads from cache dir.
enum MonacoCache {
    static let monacoVersion = "0.52.2"

    private static let cacheDirectoryName = "monaco-\(monacoVersion)"

    /// Files needed for Monaco to work offline (relative to vs/).
    private static let requiredFiles = [
        "loader.js",
        "editor/editor.main.css",
        "editor/editor.main.js",
        "editor/editor.main.nls.js",
        "base/worker/workerMain.js",
        "base/common/worker/simpleWorker.nls.js",
    ]

    /// The local directory containing cached Monaco files.
    /// Returns nil if not yet cached.
    static var cacheDirectory: URL? {
        let dir = cacheBaseDirectory.appendingPathComponent(cacheDirectoryName)
        let marker = dir.appendingPathComponent(".complete")
        guard FileManager.default.fileExists(atPath: marker.path) else { return nil }
        return dir
    }

    private static var cacheBaseDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("cmux", isDirectory: true)
    }

    /// The `vs/` directory path for Monaco require.config.
    /// Falls back to CDN URL if local cache isn't ready.
    static var vsPath: String {
        if let dir = cacheDirectory {
            return dir.appendingPathComponent("vs").path
        }
        return "https://cdn.jsdelivr.net/npm/monaco-editor@\(monacoVersion)/min/vs"
    }

    /// URL for the Monaco loader.js — local file or CDN fallback.
    static var loaderURL: String {
        if let dir = cacheDirectory {
            return dir.appendingPathComponent("vs/loader.js").path
        }
        return "https://cdn.jsdelivr.net/npm/monaco-editor@\(monacoVersion)/min/vs/loader.js"
    }

    /// URL for the Monaco CSS — local file or CDN fallback.
    static var editorCSSURL: String {
        if let dir = cacheDirectory {
            return dir.appendingPathComponent("vs/editor/editor.main.css").path
        }
        return "https://cdn.jsdelivr.net/npm/monaco-editor@\(monacoVersion)/min/vs/editor/editor.main.css"
    }

    /// Whether the cache is fully populated.
    static var isCached: Bool {
        cacheDirectory != nil
    }

    /// Prefetch Monaco files in the background. Safe to call multiple times.
    static func prefetch() {
        if isCached { return }
        DispatchQueue.global(qos: .utility).async {
            downloadMonaco()
        }
    }

    private static func downloadMonaco() {
        let targetDir = cacheBaseDirectory.appendingPathComponent(cacheDirectoryName)
        let vsDir = targetDir.appendingPathComponent("vs")
        let marker = targetDir.appendingPathComponent(".complete")

        // Already done
        if FileManager.default.fileExists(atPath: marker.path) { return }

        do {
            try FileManager.default.createDirectory(at: vsDir, withIntermediateDirectories: true)
        } catch {
            return
        }

        let baseURL = "https://cdn.jsdelivr.net/npm/monaco-editor@\(monacoVersion)/min/vs/"
        let session = URLSession(configuration: .default)

        for file in requiredFiles {
            let remoteURL = URL(string: baseURL + file)!
            let localPath = vsDir.appendingPathComponent(file)

            // Skip if already downloaded
            if FileManager.default.fileExists(atPath: localPath.path) { continue }

            // Create parent dir
            let parentDir = localPath.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

            // Synchronous download (we're on a background queue)
            let semaphore = DispatchSemaphore(value: 0)
            var downloadError: Error?

            let task = session.downloadTask(with: remoteURL) { tempURL, _, error in
                defer { semaphore.signal() }
                if let error { downloadError = error; return }
                guard let tempURL else { downloadError = NSError(domain: "MonacoCache", code: 1); return }
                do {
                    try? FileManager.default.removeItem(at: localPath)
                    try FileManager.default.moveItem(at: tempURL, to: localPath)
                } catch { downloadError = error }
            }
            task.resume()
            semaphore.wait()

            if downloadError != nil {
                // Clean up partial download and abort
                try? FileManager.default.removeItem(at: targetDir)
                return
            }
        }

        // Mark complete
        FileManager.default.createFile(atPath: marker.path, contents: nil)
    }
}
