public import CmuxNextCompat
import Foundation

/// The bundled shared chunks (`Resources/pages/_shared`, served as `cmux-page://cmux.shared/`) held
/// in memory, so ``PageSchemeHandler`` answers a shared request in the turn WebKit asks, with no
/// task hop and no disk read (plans/cmux-next/chrome-parity/p13-webui.md, task 093).
///
/// Chrome serves `chrome://resources` the same way: `WebUIDataSourceImpl::StartDataRequest`
/// (content/browser/webui/web_ui_data_source_impl.cc) answers a bundled resource id from
/// `ui::ResourceBundle::LoadDataResourceBytes` (ui/base/resource/resource_bundle.cc) in the request's
/// own task, because the bytes are already in memory. cmux reads the files fully once, off the main
/// thread (``load(from:runner:)``), rather than mapping them: a mapped page would fault on the main
/// thread on its first request.
///
/// The table is immutable and holds only regular `.js` and `.css` files that lie inside the bundled
/// root; a symbolic link, another type, or a file past ``defaultByteLimit`` is left out and takes the
/// handler's async path. ``WebBundleOverlay`` holds the app's one table and hands it out only while
/// it serves the bundle, so a web update never reaches it; the handler also skips it under a dev
/// override (``PageSchemeHandler/sharedReply(to:)``).
public nonisolated final class PageSharedChunkCache: Sendable {
    /// The origin host of the shared chunks.
    static let host = "cmux.shared"
    /// The shared chunks' folder inside the bundled pages folder.
    static let directory = "_shared"
    /// The file types the shared root serves.
    static let servedExtensions: Set<String> = ["js", "css"]
    /// The most bytes the table holds (the shared first load is at most 400 KB; lazy chunks add more).
    static let defaultByteLimit = 16 << 20

    /// One file's answer.
    nonisolated struct Chunk: Sendable, Equatable {
        let mimeType: String
        let body: Data
    }

    /// Why the table could not be read.
    nonisolated enum LoadError: Error, Equatable {
        /// The root is missing or is not a folder.
        case notADirectory(URL)
    }

    /// Files by their path below the root (`react-3F2A.js`, `chunks/x-91B0.css`).
    let chunks: [String: Chunk]

    init(chunks: [String: Chunk]) {
        self.chunks = chunks
    }

    /// Reads every served file inside `root` (blocking; ``load(from:runner:)`` runs it on the files
    /// lane), in path order; a file that would take the table past `byteLimit` is left out.
    init(reading root: URL, byteLimit: Int = PageSharedChunkCache.defaultByteLimit) throws(LoadError) {
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.checked.fileExists(atPath: base.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw .notADirectory(root)
        }
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
        let found = FileManager.checked.enumerator(at: base, includingPropertiesForKeys: keys,
                                                   options: [.skipsHiddenFiles])?.compactMap { $0 as? URL } ?? []
        var table: [String: Chunk] = [:]
        var total = 0
        for (relative, file) in found.compactMap({ Self.servedFile($0, base: base) }).sorted(by: { $0.0 < $1.0 }) {
            guard let body = try? Data(blockingContentsOf: file), total + body.count <= byteLimit else { continue }
            total += body.count
            table[relative] = Chunk(mimeType: PageSchemeHandler.mimeType(forExtension: file.pathExtension), body: body)
        }
        chunks = table
    }

    /// Reads the table at `root` on the files lane at a declared priority.
    ///
    /// - Throws: ``LoadError`` for a missing root; `CancellationError` when shutdown dropped the read.
    static func load(from root: URL, runner: any MayBlockRunner,
                     priority: MayBlockPriority = .userVisible) async throws -> PageSharedChunkCache {
        try await runner.runFiles(priority) { try PageSharedChunkCache(reading: root) }
    }

    /// The table of this module's bundled shared folder, read on the files lane: the app's one read at
    /// launch. Nil when the bundle has no shared folder or shutdown dropped the read.
    public static func loadBundled(runner: any MayBlockRunner) async -> PageSharedChunkCache? {
        guard let root = bundledRoot else { return nil }
        return try? await load(from: root, runner: runner)
    }

    /// This module's bundled shared folder, nil when the bundle has none.
    static var bundledRoot: URL? {
        Bundle.module.url(forResource: directory, withExtension: nil, subdirectory: "pages")
    }

    /// The chunk `url` names: a `cmux-page://cmux.shared/` URL whose path, with no `.` or `..`
    /// component, is in the table. Nil otherwise.
    func chunk(for url: URL) -> Chunk? {
        guard url.scheme?.lowercased() == PageDescriptor.scheme, url.host?.lowercased() == Self.host else { return nil }
        let components = url.path.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty, !components.contains(where: { $0 == "." || $0 == ".." }) else { return nil }
        return chunks[components.joined(separator: "/")]
    }

    /// `file`'s path below `base` when it is a regular served file inside it, else nil.
    private static func servedFile(_ file: URL, base: URL) -> (String, URL)? {
        guard servedExtensions.contains(file.pathExtension.lowercased()),
              let values = try? file.blockingResourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
        let real = file.standardizedFileURL.resolvingSymlinksInPath()
        guard real.path.hasPrefix(base.path + "/") else { return nil }
        return (String(real.path.dropFirst(base.path.count + 1)), real)
    }
}
