import CmuxNextDesign
import CmuxNextIcons
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

    var icon: IconName {
        switch self {
        case .markdown: .fileText
        case .editor: .code
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

    /// A file of another machine (#25581) whose machine did not answer.
    static func remoteOffline(_ machine: String) -> String {
        String(format: String(localized: "filePages.remote.offline",
                              defaultValue: "“%@” is not connected. The file shows again when it reconnects.",
                              table: "FilePages", bundle: .module), machine)
    }
    /// A file of another machine (#25581) larger than one write to it can carry.
    static func remoteTooLargeToSave(_ machine: String) -> String {
        String(format: String(localized: "filePages.remote.tooLargeToSave",
                              defaultValue: "This file is too large to save to “%@” from this Mac. Files up to 12 MB save here.",
                              table: "FilePages", bundle: .module), machine)
    }


    /// A machine whose cmux does not serve its files (an older daemon, a machine that is no Cloud VM).
    static func remoteNoFiles(_ machine: String) -> String {
        String(format: String(localized: "filePages.remote.noFiles",
                              defaultValue: "“%@” does not share its files with this Mac. Update cmux on it to open its files here.",
                              table: "FilePages", bundle: .module), machine)
    }

    /// A path the machine refuses: outside its home folder, or not readable there.
    static func remoteDenied(_ machine: String) -> String {
        String(format: String(localized: "filePages.remote.denied",
                              defaultValue: "“%@” did not allow reading this file. Files in its home folder open here.",
                              table: "FilePages", bundle: .module), machine)
    }

    /// An image, PDF or media file of another machine: this Mac previews only its own files.
    static func remotePreview(_ name: String) -> String {
        String(format: String(localized: "filePages.remote.preview",
                              defaultValue: "“%@” is on another machine. cmux opens text files from there.",
                              table: "FilePages", bundle: .module), name)
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

    /// The Copy Settings from VS Code or Zed action found no other editor's settings.
    static var noEditorSettings: String {
        String(localized: "filePages.editorSettings.none",
               defaultValue: "No VS Code, Cursor, Windsurf, VSCodium or Zed settings were found.", table: "FilePages", bundle: .module)
    }

    /// The action copied `count` keys from `from` (a product name) into cmux.json.
    static func editorSettingsCopied(_ count: Int, from: String) -> String {
        String(format: String(localized: "filePages.editorSettings.copied",
                              defaultValue: "Code editor settings from %1$@ copied into cmux.json: %2$ld.", table: "FilePages", bundle: .module),
               from, count)
    }

    static var noPane: String {
        String(localized: "filePages.noPane", defaultValue: "No pane is open to show the file.", table: "FilePages", bundle: .module)
    }
}
