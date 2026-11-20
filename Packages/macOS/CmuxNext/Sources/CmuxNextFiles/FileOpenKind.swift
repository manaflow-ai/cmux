public import Foundation
import UniformTypeIdentifiers

/// How cmux shows a file a person opens: the one rule behind every "open" in a chat (an
/// attachment, a `file://` link chip, an agent's path) and in the Files pane.
///
/// The kind comes from the name (and, for folders, the disk), so a menu can be built before a
/// file's bytes are fetched. See plans/cmux-next/files-finder-parity-DESIGN.md, section 1.
///
/// ```swift
/// switch FileOpenKind(fileName: "index.html", isDirectory: false, isPackage: false) {
/// case .web: openInBrowserTab(url)   // the rendered page
/// default: break
/// }
/// ```
public enum FileOpenKind: Sendable, Equatable {
    /// A Markdown document: the Markdown page.
    case markdown
    /// A web page (HTML, XHTML, SVG): a cmux browser tab renders it.
    case web
    /// An image, PDF, audio or video file: the browser tab's preview, which runs nothing.
    case preview
    /// Text, code or a file of unknown type: the code editor page (read only when binary).
    case editor
    /// A folder: a Files pane tab on it.
    case folder
    /// An app or another package: only the system opens it.
    case app
    /// A document of a known type cmux cannot show (Office files, archives, disk images): shown
    /// selected in a Files pane tab from a chat, opened in its app from the Files pane.
    case other

    /// Whether only a person's own click may open this kind this way: an app runs code outside
    /// cmux, so an agent's or a script's open (`cmux file open`) never launches it. A web page is
    /// not one: it renders in a sandboxed browser tab for an agent too (u18051), as any URL an
    /// agent opens does, with its source one click away (Open as Text).
    public var needsUserChoice: Bool { self == .app }

    /// Whether a file of this kind also opens as its source text in the code editor ("Open as
    /// Text", u9489): true for the pages cmux renders (Markdown, HTML, SVG). Other files already
    /// open as text (``editor``) or have no text to show.
    public var opensAsText: Bool { self == .web || self == .markdown }

    /// The kind of a file named `fileName`.
    ///
    /// - Parameters:
    ///   - fileName: the last path component; only its extension is read for files.
    ///   - isDirectory: the item is a directory (a folder or a package).
    ///   - isPackage: the system treats the directory as one item (an app, a bundle).
    public init(fileName: String, isDirectory: Bool, isPackage: Bool) {
        let ext = (fileName as NSString).pathExtension.lowercased()
        if isDirectory {
            self = isPackage || Self.packageExtensions.contains(ext) ? .app : .folder
            return
        }
        if Self.markdownExtensions.contains(ext) { self = .markdown; return }
        if Self.webExtensions.contains(ext) { self = .web; return }
        if Self.previewExtensions.contains(ext) { self = .preview; return }
        if ext.isEmpty || Self.textExtensions.contains(ext) { self = .editor; return }
        guard let type = UTType(filenameExtension: ext), type.isDeclared else {
            // An extension the system does not know is most often code (`.tsx`, `.zig`).
            self = .editor
            return
        }
        let text: [UTType] = [.text, .sourceCode, .script, .json, .xml, .propertyList, .yaml]
        self = text.contains { type.conforms(to: $0) } ? .editor : .other
    }

    /// The kind of the item at `url`, reading the disk for folders and packages; nil when nothing
    /// is there.
    public init?(url: URL) {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        guard let values, let isDirectory = values.isDirectory else { return nil }
        self.init(fileName: url.lastPathComponent, isDirectory: isDirectory, isPackage: values.isPackage ?? false)
    }

    /// The local web page a browser tab at `page` renders (a `file://` HTML or SVG file), whose
    /// source Edit Source (`browser.editSource`, u18051) opens in the code editor.
    ///
    /// - Parameter page: the tab's URL string.
    /// - Returns: the file, or nil for a web site, a preview, any other file or no URL.
    public static func sourceFile(ofPage page: String?) -> URL? {
        guard let page, let url = URL(string: page), url.isFileURL,
              FileOpenKind(fileName: url.lastPathComponent, isDirectory: false, isPackage: false) == .web else { return nil }
        return URL(fileURLWithPath: url.path)
    }

    /// The file Open as Page (`file.openAsPage`, u18462) renders from a code editor tab showing
    /// `source`: an HTML, SVG or Markdown file (``opensAsText``), as a browser tab or the markdown page.
    ///
    /// - Parameter source: the file the code editor tab shows.
    /// - Returns: `source`, or nil for a file cmux shows only as text, or no file.
    public static func renderedFile(ofSource source: URL?) -> URL? {
        guard let source, source.isFileURL,
              FileOpenKind(fileName: source.lastPathComponent, isDirectory: false, isPackage: false).opensAsText else { return nil }
        return source
    }

    /// The file a tab's other view shows (Edit Source, Open as Page, u18462).
    ///
    /// - Parameters:
    ///   - asText: true for Edit Source (the source of a rendered page), false for Open as Page.
    ///   - editorFile: the file the tab shows in the code editor, if it is a code editor tab.
    ///   - markdownFile: the file the tab shows in the markdown page, if it is one.
    ///   - pageURL: the tab's URL, if it is a browser tab.
    /// - Returns: the file to open in the other view, or nil when the tab has none.
    public static func otherView(asText: Bool, editorFile: URL?, markdownFile: URL?, pageURL: String?) -> URL? {
        asText ? markdownFile ?? sourceFile(ofPage: pageURL) : renderedFile(ofSource: editorFile)
    }

    /// Markdown names (the Markdown page's own list plus the common long forms).
    public static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mkdn"]

    /// Pages a browser tab renders.
    public static let webExtensions: Set<String> = ["html", "htm", "xhtml", "xht", "shtml", "svg"]

    /// Files the browser tab previews: images, PDF and the audio and video it plays.
    public static let previewExtensions: Set<String> = [
        "png", "jpg", "jpeg", "jpe", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp", "ico", "avif", "pdf",
        "mp4", "mov", "m4v", "webm", "mp3", "m4a", "wav", "aac", "flac", "ogg", "oga", "ogv", "ogm",
    ]

    /// Text the system types oddly (`.ts` is an MPEG stream to it) or not at all.
    static let textExtensions: Set<String> = [
        "ts", "tsx", "jsx", "mjs", "cjs", "rs", "go", "zig", "swift", "kt", "toml", "lock", "env", "ini", "cfg",
        "conf", "log", "csv", "tsv", "sql", "graphql", "proto", "vue", "svelte", "lua", "nix", "gradle",
    ]

    /// Directory names that are one item even when the disk does not say so.
    static let packageExtensions: Set<String> = [
        "app", "framework", "bundle", "plugin", "kext", "photoslibrary", "xcarchive", "appex", "prefpane", "saver",
    ]
}
