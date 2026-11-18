public import Foundation
import CmuxNextCompat

/// The font files the agent chat declares (`agentPane.display.font.faces`), so a theme's font pack
/// can ship the faces its `font.uiFamily` and `font.proseFamily` name. The Rust reader is
/// cmux-tui/crates/cmux-config/src/font_faces.rs (`cmux theme check`); both take the same entries.
///
/// The setting is a map: key = one family name, optionally suffixed `:italic`; value = `file:PATH`,
/// absolute or at `~` (a theme file's relative path already resolved against the themes folder,
/// ``ThemeFileOverlay``). A face is a plain file (no symbolic link) of at most ``maximumBytes``,
/// with a `woff2`, `woff`, `ttf` or `otf` extension that matches its first bytes; at most
/// ``maximumFaces`` are read, in key order. Each becomes a `data:font/<kind>;base64,...` URL for
/// the chat page, which declares it as an `@font-face`. A bad entry is skipped; the rest apply.
///
/// ```swift
/// let faces = ChatFontFaces.dataURLs(["Lora:italic": "file:~/Fonts/Lora-Italic.woff2"])
/// // ["Lora:italic": "data:font/woff2;base64,d09GMg..."]
/// ```
public nonisolated enum ChatFontFaces {
    /// The most faces one map declares; entries past it (in key order) are skipped.
    public static let maximumFaces = 8
    /// The most one face file may be: 2 MiB.
    public static let maximumBytes = 2 << 20
    /// The one key suffix a face may carry.
    public static let italicSuffix = ":italic"
    /// The value prefix of a face file.
    public static let filePrefix = "file:"
    /// The face file types, by extension.
    public static let extensions = ["woff2", "woff", "ttf", "otf"]
    /// Characters a face's family may not hold beyond what the font family rows refuse: one family,
    /// never a stack, and nothing that ends a CSS string or block.
    static let refusedCharacters = CharacterSet(charactersIn: ",;{}\\'<>")

    /// A face file's type from its first bytes: `woff2` (`wOF2`), `woff` (`wOFF`), `ttf`
    /// (`00 01 00 00` or `true`) or `otf` (`OTTO`).
    ///
    /// - Parameter bytes: The file's first bytes (four are enough).
    /// - Returns: The type, or nil when the bytes start no font file.
    public static func kind(of bytes: some Collection<UInt8>) -> String? {
        let head = Array(bytes.prefix(4))
        guard head.count == 4 else { return nil }
        switch head {
        case Array("wOF2".utf8): return "woff2"
        case Array("wOFF".utf8): return "woff"
        case [0, 1, 0, 0], Array("true".utf8): return "ttf"
        case Array("OTTO".utf8): return "otf"
        default: return nil
        }
    }

    /// The page's key of one map key: the trimmed family, with `:italic` for the italic face.
    ///
    /// - Parameter key: A map key such as `"Lora:italic"`.
    /// - Returns: The key the page reads, or nil when `key` is not one family, optionally `:italic`.
    public static func pageKey(_ key: String) -> String? {
        var family = Substring(key)
        var italic = false
        if let colon = key.lastIndex(of: ":") {
            guard key[colon...] == italicSuffix else { return nil }
            family = key[..<colon]
            italic = true
        }
        let trimmed = family.trimmingCharacters(in: .whitespaces)
        guard TerminalFontSetting().isValidFamily(trimmed), trimmed.rangeOfCharacter(from: refusedCharacters) == nil else { return nil }
        return italic ? trimmed + italicSuffix : trimmed
    }

    /// The file a face value names: `file:` and an absolute path, or one at `~`.
    ///
    /// - Parameter value: The map value.
    /// - Returns: The absolute path, or nil for any other value.
    public static func path(_ value: JSONValue) -> String? {
        guard let raw = value.stringValue, raw.hasPrefix(filePrefix) else { return nil }
        let rest = String(raw.dropFirst(filePrefix.count))
        if rest == "~" || rest.hasPrefix("~/") { return NSString(string: rest).expandingTildeInPath }
        return rest.hasPrefix("/") ? rest : nil
    }

    /// Every good entry of a faces map as the page's `{family[:italic]: data URL}`; bad entries are
    /// skipped. Reads each file only when its path, size or modification time changed since the last
    /// read (``cache``). File I/O: call it off the main thread.
    ///
    /// - Parameter faces: The setting's map.
    /// - Returns: The data URL of each face that loads, by page key.
    public static func dataURLs(_ faces: [String: JSONValue]) -> [String: String] {
        var loaded: [String: String] = [:]
        for key in faces.keys.sorted().prefix(maximumFaces) {
            guard let pageKey = pageKey(key), let value = faces[key], let path = path(value),
                  let url = dataURL(path: path) else { continue }
            loaded[pageKey] = url
        }
        return loaded
    }

    /// One file's data URL, or nil when it is no face: not a plain file, too large, an extension
    /// that is not a face type or does not match the bytes.
    static func dataURL(path: String) -> String? {
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, Int(info.st_size) <= maximumBytes,
              let named = extensions.first(where: { $0 == (path as NSString).pathExtension.lowercased() }) else { return nil }
        let stamp = Stamp(path: path, size: Int64(info.st_size), modified: info.st_mtimespec.tv_sec, modifiedNanoseconds: info.st_mtimespec.tv_nsec)
        if let known = cache.withLock({ $0[path] }), known.stamp == stamp { return known.url }
        guard let bytes = try? Data(blockingContentsOf: URL(fileURLWithPath: path)), bytes.count <= maximumBytes,
              kind(of: bytes) == named else {
            cache.withLock { $0[path] = nil }
            return nil
        }
        let url = "data:font/\(named);base64,\(bytes.base64EncodedString())"
        cache.withLock { cache in
            // Bounded: a map holds at most maximumFaces, so a full cache only holds stale paths.
            if cache.count >= maximumFaces * 4 { cache.removeAll() }
            cache[path] = Cached(stamp: stamp, url: url)
        }
        return url
    }

    /// What a cached read was of: the file at a path, with its size and modification time.
    struct Stamp: Equatable, Sendable {
        let path: String
        let size: Int64
        let modified: Int
        let modifiedNanoseconds: Int
    }

    struct Cached: Sendable {
        let stamp: Stamp
        let url: String
    }

    /// The data URLs read so far, by path.
    static let cache = Mutex<[String: Cached]>([:])
}
