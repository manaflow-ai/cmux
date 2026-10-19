import Foundation
import CmuxNextSettings

/// A project's own favicon for its picker badge (`project.icon {cwd}`): the New Tab page's folder
/// strip and the composer's folder menu draw it in place of the letter tile. The page reads no
/// file (CSP `img-src data:`), so the host looks for a few well-known icon files in the folder and
/// answers a small data URL.
///
/// Never a look inside a privacy-protected folder (LAUNCH-NO-TCC-PROMPTS): the folder and every
/// candidate go through `ChatRootValidator` first, which checks the spelling, then resolves links
/// with `readlink` only, and refuses `/`, the home folder, other volumes and the protected folders
/// of the one list (cmux-tui/crates/acpmux/data/protected-folders.json). A refused path is never
/// stat'ed or read, so a favicon linked into Documents is no icon.
nonisolated struct AgentPaneProjectIcon: Sendable {
    /// Larger files are skipped: a tile is 20pt, and the answer crosses the bridge as base64.
    static let maximumBytes = 64 * 1024
    /// Best first: a vector or a 180px touch icon draws sharper in the tile than a 16px `.ico`.
    static let names = ["favicon.svg", "icon.svg", "apple-touch-icon.png", "favicon.png", "icon.png", "favicon.ico"]
    /// The folder itself and where web frameworks keep their icons (Next.js `app/`, Vite and
    /// Next.js `public/`, SvelteKit `static/`).
    static let folders = ["", "public", "static", "app", "src/app", "assets"]

    /// A regular file's size and modification date, or nil (the cache key with its path).
    var stat: @Sendable (String) -> File?
    var read: @Sendable (String) -> Data?
    private let validator: ChatRootValidator

    struct File: Equatable, Sendable {
        var size: Int
        var modified: Date
    }

    init(home: String = NSHomeDirectory()) {
        validator = ChatRootValidator(home: home)
        stat = { path in
            guard let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
                  values.isRegularFile == true, let size = values.fileSize else { return nil }
            return File(size: size, modified: values.contentModificationDate ?? .distantPast)
        }
        read = { path in
            guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
            defer { try? handle.close() }
            return try? handle.read(upToCount: AgentPaneProjectIcon.maximumBytes + 1)
        }
    }

    /// Every path looked for in `folder`, best first.
    static func candidates(in folder: String) -> [String] {
        let base = folder.hasSuffix("/") ? String(folder.dropLast()) : folder
        return names.flatMap { name in folders.map { sub in sub.isEmpty ? "\(base)/\(name)" : "\(base)/\(sub)/\(name)" } }
    }

    /// The first candidate in `folder` that may be read, is a regular file and is small enough.
    func pick(in folder: String) -> (path: String, file: File)? {
        guard folder.hasPrefix("/"), validator.refusal(folder) == nil else { return nil }
        for path in Self.candidates(in: folder) where validator.refusal(path) == nil {
            if let file = stat(path), file.size > 0, file.size <= Self.maximumBytes { return (path, file) }
        }
        return nil
    }

    /// The data URL of an image file, typed by its bytes; nil for anything that is not one.
    func dataURL(_ path: String) -> String? {
        guard let data = read(path), !data.isEmpty, data.count <= Self.maximumBytes, let type = Self.imageType(data) else { return nil }
        return "data:\(type);base64,\(data.base64EncodedString())"
    }

    /// The icon of the project at `folder`, uncached.
    func icon(in folder: String) -> String? {
        pick(in: folder).flatMap { dataURL($0.path) }
    }

    static func imageType(_ data: Data) -> String? {
        let bytes = [UInt8](data.prefix(8))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if bytes.starts(with: [0x00, 0x00, 0x01, 0x00]) { return "image/x-icon" }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if bytes.starts(with: [0x47, 0x49, 0x46, 0x38]) { return "image/gif" }
        // An SVG as an <img> runs no script; its root element must show up front.
        if let head = String(data: data.prefix(1024), encoding: .utf8)?.lowercased(), head.contains("<svg") { return "image/svg+xml" }
        return nil
    }
}

/// The icons the pickers asked for, read off the main actor and kept by file path and
/// modification date: a project's icon is read once until the file changes.
actor AgentPaneProjectIcons {
    static let shared = AgentPaneProjectIcons(reader: AgentPaneProjectIcon())

    private let reader: AgentPaneProjectIcon
    private var cache: [String: (file: AgentPaneProjectIcon.File, url: String?)] = [:]

    init(reader: AgentPaneProjectIcon) {
        self.reader = reader
    }

    func icon(for folder: String) -> String? {
        guard let picked = reader.pick(in: folder) else { return nil }
        if let known = cache[picked.path], known.file == picked.file { return known.url }
        let url = reader.dataURL(picked.path)
        if cache.count >= 512 { cache.removeAll() }
        cache[picked.path] = (picked.file, url)
        return url
    }
}
