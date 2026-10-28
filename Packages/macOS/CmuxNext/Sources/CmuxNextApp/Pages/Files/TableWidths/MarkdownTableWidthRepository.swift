import CmuxNextCompat
import CryptoKit
import Foundation

/// Keeps Markdown table column widths with the file, in its `com.cmux.markdown.tables` extended
/// attribute, and mirrors them into a small app-side copy per file under Application Support
/// (plans/cmux-next/MARKDOWN-TABLE-WIDTHS-DESIGN.md). The attribute travels with the file (a
/// rename, a Finder copy, Time Machine) and changes neither its bytes nor its modification time, so
/// git, the file watch and the page's save hash never see a resize. The app-side copy answers when
/// the attribute is gone or refused: a volume without attributes (some SMB, FAT, exFAT), a file the
/// user cannot write, or an editor or `git checkout` that replaced the file and dropped them. The
/// copy is one file per path, bounded to ``fallbackLimit`` files, oldest first out.
actor MarkdownTableWidthRepository: MarkdownTableWidthStoring {
    /// The actor's own serial queue: its file calls block this queue, never a cooperative pool thread
    /// (Chrome runs file work on a MayBlock sequence, base/task/task_traits.h).
    private nonisolated let queue = DispatchSerialQueue(label: "com.cmuxterm.next.files.table-widths", qos: .userInitiated)

    /// Runs the actor on ``queue``.
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    /// The extended attribute's name.
    static let attributeName = "com.cmux.markdown.tables"
    /// The largest value kept; the page's own cap keeps far below it.
    static let valueLimit = 16 * 1024
    /// The attribute of a file's viewer comments (``ViewerCommentList``).
    static let commentsAttributeName = "com.cmux.markdown.comments"
    /// The largest comments value kept: under ``DarwinExtendedAttributes/readLimit``.
    static let commentsValueLimit = 60 * 1024
    /// How many files the app-side copy remembers.
    static let fallbackLimit = 1000
    /// The copy is pruned on the first write and then every this many writes.
    static let pruneEvery = 32

    private let attributes: any ExtendedAttributeAccess
    /// This store's attribute (``attributeName`` for table widths, ``commentsAttributeName`` for viewer comments).
    let name: String
    /// The largest value this store keeps.
    let maxBytes: Int
    private let fallback: URL?
    private let limit: Int
    private var writes = 0

    /// - Parameters:
    ///   - attributes: The extended attribute access (tests pass one that refuses).
    ///   - fallback: The folder of the app-side copy; nil keeps no copy.
    ///   - fallbackLimit: How many files the copy remembers.
    ///   - name: The extended attribute; the same store keeps a file's viewer comments under
    ///     ``commentsAttributeName`` (viewer-comments-DESIGN.md "Comments in the viewer").
    ///   - maxBytes: The largest value kept.
    init(attributes: any ExtendedAttributeAccess = DarwinExtendedAttributes(), fallback: URL?,
         fallbackLimit: Int = MarkdownTableWidthRepository.fallbackLimit,
         name: String = MarkdownTableWidthRepository.attributeName, maxBytes: Int = MarkdownTableWidthRepository.valueLimit) {
        self.attributes = attributes
        self.name = name
        self.maxBytes = maxBytes
        self.fallback = fallback
        self.limit = fallbackLimit
    }

    /// `~/Library/Application Support/<bundle id>/MarkdownTableWidths` (per tagged build).
    static func defaultFallbackDirectory(bundle: Bundle = .main, folder: String = "MarkdownTableWidths") -> URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return support.appending(path: bundle.bundleIdentifier ?? "cmux-next", directoryHint: .isDirectory)
            .appending(path: folder, directoryHint: .isDirectory)
    }

    func read(_ path: String) async -> Data? {
        if let value = attributes.read(name, at: path), value.count <= maxBytes { return value }
        guard let url = copyURL(for: path), let data = try? Data(contentsOf: url),
              let copy = try? JSONDecoder().blockingDecode(Copy.self, from: data), copy.path == path else { return nil }
        // Reading counts as use for the oldest-first pruning.
        try? FileManager.checked.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return Data(copy.value.utf8)
    }

    @discardableResult
    func write(_ path: String, _ value: Data?) async -> MarkdownTableWidthWrite {
        if let value, value.count > maxBytes { return MarkdownTableWidthWrite(attribute: false, fallback: false) }
        let attribute = if let value {
            attributes.write(name, value, at: path)
        } else {
            attributes.remove(name, at: path)
        }
        return MarkdownTableWidthWrite(attribute: attribute, fallback: writeCopy(path, value))
    }

    // MARK: App-side copy

    nonisolated private struct Copy: Codable {
        let path: String
        let value: String
    }

    private func copyURL(for path: String) -> URL? {
        let name = SHA256.hash(data: Data(path.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return fallback?.appending(path: "\(name).json")
    }

    private func writeCopy(_ path: String, _ value: Data?) -> Bool {
        guard let fallback, let url = copyURL(for: path) else { return false }
        guard let value, let text = String(data: value, encoding: .utf8) else {
            try? FileManager.checked.removeItem(at: url)
            return !FileManager.checked.fileExists(atPath: url.path)
        }
        do {
            try FileManager.checked.createDirectory(at: fallback, withIntermediateDirectories: true)
            try JSONEncoder().encode(Copy(path: path, value: text)).write(to: url, options: .atomic)
        } catch {
            return false
        }
        if writes % Self.pruneEvery == 0 { prune(fallback) }
        writes += 1
        return true
    }

    /// Drops the least recently used copies past ``limit``.
    private func prune(_ folder: URL) {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let files = try? FileManager.checked.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys),
              files.count > limit else { return }
        let dated = files.map { file in
            (file, (try? file.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast)
        }
        for (file, _) in dated.sorted(by: { $0.1 < $1.1 }).prefix(files.count - limit) {
            try? FileManager.checked.removeItem(at: file)
        }
    }
}
