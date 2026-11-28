public import AppKit
public import Foundation
import UniformTypeIdentifiers

/// Where the page asks to open a file: a tab beside the agent, or the editor.
public nonisolated enum AgentPaneFileTarget: String, Equatable, Sendable {
    case tab
    case editor
}

/// Opening a file the page names. The path comes from an agent's tool calls,
/// so the host opens only an existing regular file, and never with the file's
/// own handler: a tab shows only a file WebKit does not run as a page, and the
/// editor is the app for source code or plain text, so a script, a web page or
/// an app bundle is never run. The file is checked, then opened by URL; whoever
/// could swap it in between can already write the folder, and nothing it swaps
/// in runs, since the app that opens it is fixed.
public nonisolated enum AgentPaneFileOpen {
    /// The file at `path`, or nil unless `path` is absolute and names an
    /// existing regular file (after links), not a folder or a package.
    public static func resolve(_ path: String, fileManager: FileManager = .default) -> URL? {
        guard path.hasPrefix("/"), !path.contains("\u{0}") else { return nil }
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue,
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isPackageKey]),
              values.isRegularFile == true, values.isPackage != true else { return nil }
        return url
    }

    /// Extensions WebKit loads as a page with script, styles or links out, which
    /// it maps from the extension alone for a `file://` URL.
    private static let pageExtensions: Set<String> = [
        "htm", "html", "shtml", "xht", "xhtml", "xml", "xsl", "xslt", "svg", "svgz", "rss", "atom", "rdf",
        "webarchive", "mht", "mhtml", "webloc", "inetloc", "url"
    ]

    /// Audio and video a tab plays (an explicit list: the system types many
    /// containers, such as AVI or MKV, that a tab cannot play).
    public static let mediaExtensions: Set<String> = [
        "mp4", "mov", "m4v", "webm", "mp3", "m4a", "wav", "aac", "flac", "ogg", "oga", "ogv", "ogm",
    ]

    /// Whether a tab may show the file at `url`. The tab loads it as a WebKit page
    /// that can read the files beside it, so it shows only a file the system types
    /// as plain text, source code, an image, a PDF or audio/video, and never a page type; a file
    /// with an unknown type or no extension, which WebKit might sniff, opens in the
    /// editor only.
    public static func showsInTab(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        guard !ext.isEmpty, !pageExtensions.contains(ext),
              let type = UTType(filenameExtension: ext), type.isDeclared else { return false }
        let page: [UTType] = [.html, .xml, .svg, .webArchive, .internetLocation]
        if page.contains(where: { type.conforms(to: $0) }) { return false }
        if type.conforms(to: .audiovisualContent) { return mediaExtensions.contains(ext) }
        let shown: [UTType] = [.plainText, .sourceCode, .image, .pdf]
        return shown.contains { type.conforms(to: $0) }
    }

    /// The app that edits text: the default for source code, else for plain text.
    @MainActor public static func editorApplication(workspace: NSWorkspace = .shared) -> URL? {
        workspace.urlForApplication(toOpen: .sourceCode) ?? workspace.urlForApplication(toOpen: .plainText)
    }
}
