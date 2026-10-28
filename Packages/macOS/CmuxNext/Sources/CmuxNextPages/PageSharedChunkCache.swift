import CmuxNextCompat
import Foundation

/// The bundled shared chunks (``PageSharedChunks/bundledRoot``, served as `cmux-page://cmux.shared/`)
/// held in memory, so ``PageSchemeHandler`` answers a shared request in the turn WebKit asks, with no
/// task hop and no disk read (plans/cmux-next/chrome-parity/p13-webui.md, task 093).
///
/// Chrome serves `chrome://resources` the same way: `WebUIDataSourceImpl::StartDataRequest`
/// (content/browser/webui/web_ui_data_source_impl.cc) answers a bundled resource from
/// `ui::ResourceBundle::LoadDataResourceBytes` (ui/base/resource/resource_bundle.cc) in the request's
/// own task, because the bytes are already in memory. cmux reads the files fully once, on the files
/// lane, rather than mapping them: a mapped page would fault on the main thread at its first request.
///
/// The table is immutable and holds only regular `.js` and `.css` files that lie inside the root it was
/// read from (``root``); a symbolic link, a hidden file, another type, or a file past
/// ``defaultByteLimit`` is left out and takes the handler's async path. ``WebBundleOverlay`` holds the
/// app's one table, read from the bundled root, and hands it out only while it serves the bundle.
nonisolated final class PageSharedChunkCache: Sendable {
    /// The most bytes the table holds (the shared first load is at most 400 KB; lazy chunks add more).
    static let defaultByteLimit = 16 << 20

    /// One file's answer: the file it was read from (its extension names the type) and its bytes.
    nonisolated struct Chunk: Sendable, Equatable {
        let file: URL
        let body: Data
    }

    /// Why the table could not be read.
    nonisolated enum LoadError: Error, Equatable {
        /// The root is missing or is not a folder.
        case notADirectory(URL)
    }

    /// The folder the table was read from, standardized (``serves(_:)``).
    let root: URL
    /// Files by their path below ``root`` (`react-3F2A.js`, `chunks/x-91B0.css`).
    let chunks: [String: Chunk]

    init(root: URL, chunks: [String: Chunk]) {
        self.root = root.standardizedFileURL
        self.chunks = chunks
    }

    /// Reads every served file inside `root` (blocking: the files lane runs it), in path order; a file
    /// that would take the table past `byteLimit` is left out.
    init(reading root: URL, byteLimit: Int = PageSharedChunkCache.defaultByteLimit) throws(LoadError) {
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.checked.fileExists(atPath: base.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw .notADirectory(root)
        }
        let found = FileManager.checked.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                                                   options: [.skipsHiddenFiles])?.compactMap { $0 as? URL } ?? []
        var table: [String: Chunk] = [:]
        var total = 0
        for (relative, file) in found.compactMap({ Self.servedFile($0, base: base) }).sorted(by: { $0.0 < $1.0 }) {
            guard let body = try? Data(blockingContentsOf: file), total + body.count <= byteLimit else { continue }
            total += body.count
            table[relative] = Chunk(file: file, body: body)
        }
        self.root = root.standardizedFileURL
        chunks = table
    }

    /// Whether the table was read from `root`: a handler serving another folder never answers from it.
    func serves(_ root: URL) -> Bool {
        self.root.path == root.standardizedFileURL.path
    }

    /// The chunk `url` names: a shared-origin URL whose path, with no `.` or `..` component, is in the
    /// table. Nil otherwise.
    func chunk(for url: URL) -> Chunk? {
        guard PageSharedChunks.isShared(url) else { return nil }
        let components = url.path.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty, !components.contains(where: { $0 == "." || $0 == ".." }) else { return nil }
        return chunks[components.joined(separator: "/")]
    }

    /// `file`'s path below `base` and its real location when it is a regular served file inside it, else nil.
    private static func servedFile(_ file: URL, base: URL) -> (String, URL)? {
        guard PageSharedChunks.servedExtensions.contains(file.pathExtension),
              let values = try? file.blockingResourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
        let real = file.standardizedFileURL.resolvingSymlinksInPath()
        guard real.path.hasPrefix(base.path + "/") else { return nil }
        return (String(real.path.dropFirst(base.path.count + 1)), real)
    }
}
