import Foundation
import CmuxNextSettings

/// A project's own favicon for its picker badge (`project.icon {cwd}`): the New Tab page's folder
/// strip and the composer's folder menu draw it in place of the letter tile. A project with none
/// answers the language its marker files name (`Package.swift`: swift), whose icon the page draws. The page reads no
/// file (CSP `img-src data:`), so the host looks for a few well-known icon files in the folder and
/// answers a small data URL.
///
/// Never a read inside a privacy-protected folder (LAUNCH-NO-TCC-PROMPTS): the folder and every
/// candidate go through `ChatRootValidator` first, which checks the spelling, then resolves links
/// with `readlink` only, and refuses `/`, the home folder, other volumes and the protected folders
/// of the one list (cmux-tui/crates/acpmux/data/protected-folders.json). The disk matches names
/// more loosely than a spelling check (`Documentſ`, `/System/Volumes/Data/Users/…`), so each path,
/// before and after its links are resolved, must also reach no protected folder by identity
/// (`reachesProtectedFolder`, `lstat` only). Resolving can lstat or readlink through a protected
/// folder, which raises no prompt; a refused path is never stat'ed for its contents, opened or read,
/// so a favicon linked into Documents is no icon. One linked elsewhere in the project is read at its
/// target.
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

    /// True when `path` may be looked at: refused neither by its spelling nor by what it reaches.
    func allows(_ path: String) -> Bool {
        validator.refusal(path) == nil && !validator.reachesProtectedFolder(path)
    }

    /// The candidates in `folder` that may be read, are regular files and are small enough, best
    /// first, each at its resolved path (a favicon linked within the project is read at its target).
    func files(in folder: String) -> [(path: String, file: File)] {
        guard folder.hasPrefix("/"), allows(folder) else { return [] }
        var found: [(path: String, file: File)] = []
        for candidate in Self.candidates(in: folder) where allows(candidate) {
            // `realpath` reads only link entries and keeps `/private`, unlike `resolvingSymlinksInPath`.
            guard let resolved = Self.realPath(candidate), resolved == candidate || allows(resolved),
                  let file = stat(resolved), file.size > 0, file.size <= Self.maximumBytes else { continue }
            found.append((resolved, file))
        }
        return found
    }

    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// The data URL of an image file, typed by its bytes; nil for anything that is not one.
    func dataURL(_ path: String) -> String? {
        guard let data = read(path), !data.isEmpty, data.count <= Self.maximumBytes, let type = Self.imageType(data) else { return nil }
        return "data:\(type);base64,\(data.base64EncodedString())"
    }

    /// Files at a project's top level that say what it is built with, best first: a framework's
    /// config before its language's manifest (a Next.js app has a package.json too). The page draws
    /// the language's icon when the project has no favicon of its own.
    static let markers: [(name: String, language: String)] = [
        ("next.config.ts", "nextjs"), ("next.config.mjs", "nextjs"), ("next.config.js", "nextjs"),
        ("svelte.config.js", "svelte"), ("astro.config.mjs", "astro"), ("vite.config.ts", "vite"),
        ("Package.swift", "swift"), ("Cargo.toml", "rust"), ("go.mod", "go"), ("build.zig", "zig"),
        ("pyproject.toml", "python"), ("setup.py", "python"), ("requirements.txt", "python"),
        ("Gemfile", "ruby"), ("tsconfig.json", "typescript"), ("package.json", "javascript"),
        ("Dockerfile", "docker"),
    ]

    /// The language of the project at `folder` from the first marker file it has, under the same
    /// rules as its icon: a marker linked into a protected folder is never stat'ed.
    func language(in folder: String) -> String? {
        guard folder.hasPrefix("/"), allows(folder) else { return nil }
        let base = folder.hasSuffix("/") ? String(folder.dropLast()) : folder
        for marker in Self.markers {
            let candidate = "\(base)/\(marker.name)"
            guard allows(candidate), let resolved = Self.realPath(candidate), resolved == candidate || allows(resolved),
                  stat(resolved) != nil else { continue }
            return marker.language
        }
        return nil
    }

    /// The icon of the project at `folder`, uncached: the first candidate that is an image.
    func icon(in folder: String) -> String? {
        files(in: folder).lazy.compactMap { dataURL($0.path) }.first
    }

    static func imageType(_ data: Data) -> String? {
        let bytes = [UInt8](data.prefix(8))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if bytes.starts(with: [0x00, 0x00, 0x01, 0x00]) { return "image/x-icon" }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if bytes.starts(with: [0x47, 0x49, 0x46, 0x38]) { return "image/gif" }
        // An SVG as an <img> runs no script; its root element must show up front.
        // Decoded leniently: the first kilobyte can end inside a character.
        if String(decoding: data.prefix(1024), as: UTF8.self).lowercased().contains("<svg") { return "image/svg+xml" }
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

    /// The project's language from its marker files, for a badge with no favicon; not cached, a
    /// few stats of the project's top level.
    func language(for folder: String) -> String? {
        reader.language(in: folder)
    }

    /// The first candidate that is an image; a cached answer stands until its file changes.
    func icon(for folder: String) -> String? {
        for picked in reader.files(in: folder) {
            if let known = cache[picked.path], known.file == picked.file {
                if let url = known.url { return url }
                continue
            }
            let url = reader.dataURL(picked.path)
            if cache.count >= 512 { cache.removeAll() }
            cache[picked.path] = (picked.file, url)
            if let url { return url }
        }
        return nil
    }
}
