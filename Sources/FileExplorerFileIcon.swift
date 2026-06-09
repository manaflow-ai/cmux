import AppKit

/// A colorful, file-type-specific icon for the file explorer.
///
/// Maps a file's name (well-known full names like `package.json` or
/// `.gitignore` first, then extension lookups) to an SF Symbol glyph and a tint color,
/// in the spirit of Seti / Material icon themes. Used by the High-Density
/// (Cursor-like) explorer style so files are distinguishable at a glance
/// instead of all sharing one gray document glyph.
struct FileExplorerFileIcon {
    /// The SF Symbol name rendered for the file.
    let symbolName: String
    /// The tint applied to the glyph.
    let color: NSColor

    /// Resolves the icon for a file name, falling back to a neutral document
    /// glyph for unknown types.
    ///
    /// - Parameter fileName: The bare file name (not the full path).
    /// - Returns: The matching ``FileExplorerFileIcon``.
    static func resolve(for fileName: String) -> FileExplorerFileIcon {
        let lower = fileName.lowercased()
        if let byName = byFullName[lower] { return byName }
        let ext = (lower as NSString).pathExtension
        if let byExt = byExtension[ext] { return byExt }
        return FileExplorerFileIcon(symbolName: "doc", color: Palette.neutral)
    }

    /// Palette of tints shared across icon mappings, tuned to read well on the
    /// dark High-Density background.
    private enum Palette {
        static let neutral = NSColor(white: 0.62, alpha: 1.0)
        static let typescript = NSColor(red: 0.29, green: 0.56, blue: 0.89, alpha: 1.0)
        static let javascript = NSColor(red: 0.95, green: 0.78, blue: 0.27, alpha: 1.0)
        static let json = NSColor(red: 0.95, green: 0.78, blue: 0.27, alpha: 1.0)
        static let markdown = NSColor(red: 0.45, green: 0.62, blue: 0.95, alpha: 1.0)
        static let env = NSColor(red: 0.55, green: 0.78, blue: 0.45, alpha: 1.0)
        static let swift = NSColor(red: 0.96, green: 0.45, blue: 0.27, alpha: 1.0)
        static let style = NSColor(red: 0.36, green: 0.66, blue: 0.92, alpha: 1.0)
        static let image = NSColor(red: 0.67, green: 0.53, blue: 0.92, alpha: 1.0)
        static let archive = NSColor(red: 0.80, green: 0.66, blue: 0.40, alpha: 1.0)
        static let git = NSColor(red: 0.94, green: 0.40, blue: 0.30, alpha: 1.0)
        static let config = NSColor(red: 0.62, green: 0.66, blue: 0.72, alpha: 1.0)
        static let html = NSColor(red: 0.90, green: 0.49, blue: 0.30, alpha: 1.0)
        static let pdf = NSColor(red: 0.86, green: 0.30, blue: 0.30, alpha: 1.0)
        static let shell = NSColor(red: 0.50, green: 0.78, blue: 0.55, alpha: 1.0)
        static let lock = NSColor(white: 0.55, alpha: 1.0)
    }

    /// Extension-keyed icon mappings.
    private static let byExtension: [String: FileExplorerFileIcon] = [
        "ts": .init(symbolName: "chevron.left.forwardslash.chevron.right", color: Palette.typescript),
        "tsx": .init(symbolName: "chevron.left.forwardslash.chevron.right", color: Palette.typescript),
        "mts": .init(symbolName: "chevron.left.forwardslash.chevron.right", color: Palette.typescript),
        "cts": .init(symbolName: "chevron.left.forwardslash.chevron.right", color: Palette.typescript),
        "js": .init(symbolName: "curlybraces", color: Palette.javascript),
        "jsx": .init(symbolName: "curlybraces", color: Palette.javascript),
        "mjs": .init(symbolName: "curlybraces", color: Palette.javascript),
        "cjs": .init(symbolName: "curlybraces", color: Palette.javascript),
        "json": .init(symbolName: "curlybraces", color: Palette.json),
        "jsonc": .init(symbolName: "curlybraces", color: Palette.json),
        "md": .init(symbolName: "doc.richtext", color: Palette.markdown),
        "markdown": .init(symbolName: "doc.richtext", color: Palette.markdown),
        "mdx": .init(symbolName: "doc.richtext", color: Palette.markdown),
        "env": .init(symbolName: "leaf", color: Palette.env),
        "swift": .init(symbolName: "swift", color: Palette.swift),
        "css": .init(symbolName: "paintbrush", color: Palette.style),
        "scss": .init(symbolName: "paintbrush", color: Palette.style),
        "sass": .init(symbolName: "paintbrush", color: Palette.style),
        "less": .init(symbolName: "paintbrush", color: Palette.style),
        "html": .init(symbolName: "chevron.left.slash.chevron.right", color: Palette.html),
        "htm": .init(symbolName: "chevron.left.slash.chevron.right", color: Palette.html),
        "png": .init(symbolName: "photo", color: Palette.image),
        "jpg": .init(symbolName: "photo", color: Palette.image),
        "jpeg": .init(symbolName: "photo", color: Palette.image),
        "gif": .init(symbolName: "photo", color: Palette.image),
        "webp": .init(symbolName: "photo", color: Palette.image),
        "svg": .init(symbolName: "photo", color: Palette.image),
        "ico": .init(symbolName: "photo", color: Palette.image),
        "zip": .init(symbolName: "doc.zipper", color: Palette.archive),
        "gz": .init(symbolName: "doc.zipper", color: Palette.archive),
        "tar": .init(symbolName: "doc.zipper", color: Palette.archive),
        "tgz": .init(symbolName: "doc.zipper", color: Palette.archive),
        "lock": .init(symbolName: "lock", color: Palette.lock),
        "yml": .init(symbolName: "gearshape", color: Palette.config),
        "yaml": .init(symbolName: "gearshape", color: Palette.config),
        "toml": .init(symbolName: "gearshape", color: Palette.config),
        "ini": .init(symbolName: "gearshape", color: Palette.config),
        "cfg": .init(symbolName: "gearshape", color: Palette.config),
        "conf": .init(symbolName: "gearshape", color: Palette.config),
        "pdf": .init(symbolName: "doc.text", color: Palette.pdf),
        "sh": .init(symbolName: "terminal", color: Palette.shell),
        "bash": .init(symbolName: "terminal", color: Palette.shell),
        "zsh": .init(symbolName: "terminal", color: Palette.shell),
    ]

    /// Full-name-keyed icon mappings, checked before the extension table so
    /// dotfiles and well-known config files get distinctive glyphs.
    private static let byFullName: [String: FileExplorerFileIcon] = [
        "package.json": .init(symbolName: "shippingbox", color: Palette.javascript),
        "package-lock.json": .init(symbolName: "lock", color: Palette.lock),
        "bun.lock": .init(symbolName: "lock", color: Palette.lock),
        "bun.lockb": .init(symbolName: "lock", color: Palette.lock),
        ".gitignore": .init(symbolName: "arrow.triangle.branch", color: Palette.git),
        ".gitattributes": .init(symbolName: "arrow.triangle.branch", color: Palette.git),
        ".env": .init(symbolName: "leaf", color: Palette.env),
        ".env.local": .init(symbolName: "leaf", color: Palette.env),
        ".env.example": .init(symbolName: "leaf", color: Palette.env),
        ".envrc": .init(symbolName: "leaf", color: Palette.env),
        "dockerfile": .init(symbolName: "shippingbox", color: Palette.config),
        "readme.md": .init(symbolName: "doc.richtext", color: Palette.markdown),
        ".vercelignore": .init(symbolName: "list.bullet", color: Palette.config),
    ]
}
