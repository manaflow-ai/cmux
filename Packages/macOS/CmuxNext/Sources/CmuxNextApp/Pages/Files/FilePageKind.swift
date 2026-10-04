import CmuxNextDesign
import CmuxNextPages
import Foundation

extension InternalPageID {
    /// The markdown page (diff-host S6), a pane tab.
    nonisolated static let markdown = InternalPageID(rawValue: "markdown")
    /// The code editor page (diff-host S7), a pane tab.
    nonisolated static let editor = InternalPageID(rawValue: "editor")
}

/// The two file pages. They share one host (``FilePageService``, ``FilePageProvider``): open,
/// watch, save, links and recents; this says where they differ.
nonisolated enum FilePageKind: String, Sendable, CaseIterable {
    case markdown
    case editor

    @MainActor var descriptor: PageDescriptor {
        switch self {
        case .markdown: .markdown
        case .editor: .editor
        }
    }

    var page: InternalPageID {
        switch self {
        case .markdown: .markdown
        case .editor: .editor
        }
    }

    /// The page's theme surface (`appearance.surfaces.markdown`, `.editor`).
    var surface: SurfaceKind {
        switch self {
        case .markdown: .markdown
        case .editor: .editor
        }
    }

    /// `cmux.markdown`, `cmux.editor`: the op prefix without its dot.
    @MainActor var namespace: String { descriptor.id }

    @MainActor func op(_ name: String) -> String { "\(namespace).\(name)" }

    /// The page's settings section (`markdown.*`, `editor.*`) and its `<config dir>/<section>/theme.css`.
    var section: String { rawValue }

    /// The viewers' recents list this page reads and records into (R89).
    @MainActor var recents: ViewerRecents.Kind {
        switch self {
        case .markdown: .markdown
        case .editor: .file
        }
    }

    var symbol: String {
        switch self {
        case .markdown: "doc.richtext"
        case .editor: "chevron.left.forwardslash.chevron.right"
        }
    }

    var title: String {
        switch self {
        case .markdown: FilePageStrings.markdownTitle
        case .editor: FilePageStrings.editorTitle
        }
    }

    /// Whether this page opens `url`: the markdown page only Markdown files, the editor any file.
    func accepts(_ url: URL) -> Bool {
        self == .editor || Self.isMarkdown(url)
    }

    static func isMarkdown(_ url: URL) -> Bool {
        ["md", "markdown"].contains(url.pathExtension.lowercased())
    }
}

/// The file pages' host strings (table `FilePages`). The pages' own labels ship with the pages.
nonisolated enum FilePageStrings {
    static var markdownTitle: String {
        String(localized: "filePages.markdown.tabTitle", defaultValue: "Markdown", table: "FilePages", bundle: .module)
    }

    static var editorTitle: String {
        String(localized: "filePages.editor.tabTitle", defaultValue: "Editor", table: "FilePages", bundle: .module)
    }

    static var noFilePage: String {
        String(localized: "filePages.noFilePage", defaultValue: "No file page has the keyboard.", table: "FilePages", bundle: .module)
    }

    static var notAFile: String {
        String(localized: "filePages.notAFile", defaultValue: "That file cannot be opened.", table: "FilePages", bundle: .module)
    }

    static func openOutsideTitle(_ path: String) -> String {
        String(format: String(localized: "filePages.openOutside.title", defaultValue: "Open “%@”?", table: "FilePages", bundle: .module), path)
    }

    static var openOutsideDetail: String {
        String(localized: "filePages.openOutside.detail", defaultValue: "A link in this page points outside the folder of the file you opened.",
               table: "FilePages", bundle: .module)
    }

    static func restoreConflict(_ name: String) -> String {
        String(format: String(localized: "filePages.restoreConflict",
                              defaultValue: "“%@” changed on disk after its recovered draft was saved. The draft is open as unsaved changes; saving replaces the file.",
                              table: "FilePages", bundle: .module), name)
    }

    static func noRecovery(_ name: String) -> String {
        String(format: String(localized: "filePages.noRecovery", defaultValue: "No crash recovery for “%@”: the file is too large.",
                              table: "FilePages", bundle: .module), name)
    }

    static var noPane: String {
        String(localized: "filePages.noPane", defaultValue: "No pane is open to show the file.", table: "FilePages", bundle: .module)
    }
}
