import AppKit
import CmuxNextAgentPane
import CmuxNextBrowser
import typealias CmuxNextDaemon.SurfaceID

/// The file viewer seam (R89 ``FileOpening``) for the file pages: every file open (Open File...,
/// the cmux picker, `file.open` and `cmux file open`, Finder drops on a file page, a followed link
/// in a markdown file) comes here. Markdown files open the markdown page, other files the code
/// editor page (read only when binary or not UTF-8), in a pane tab; images, PDFs and media keep
/// the browser tab's preview, which shows them and runs nothing.
final class FilePageOpener: FileOpening {
    // crash-allow: AppServices owns ViewerService, which owns this opener, for the app's whole life.
    private unowned let services: AppServices

    init(services: AppServices) {
        self.services = services
    }

    /// Files the browser tab previews (images, PDFs, media). An explicit list, because the system
    /// types `.ts` (TypeScript) as an MPEG transport stream.
    nonisolated static let previewExtensions: Set<String> = Set([
        "png", "jpg", "jpeg", "jpe", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp", "ico", "avif", "pdf",
    ]).union(AgentPaneFileOpen.mediaExtensions)

    /// The engine of the tab that previews `url`: WebKit for video and audio the Chromium build
    /// cannot decode (``LocalFileHandoff``), else nil (the default engine).
    nonisolated static func tabEngine(for url: URL) -> String? {
        url.localFileHandoff == .webKitTab ? BrowserEngineTag.webkit.rawValue : nil
    }

    /// The page that opens `url`, nil for a file the browser tab previews.
    nonisolated static func kind(for url: URL) -> FilePageKind? {
        if FilePageKind.isMarkdown(url) { return .markdown }
        return previewExtensions.contains(url.pathExtension.lowercased()) ? nil : .editor
    }

    func open(_ file: URL, in pane: PaneController?) -> String? {
        open(file, in: pane, userChose: true)
    }

    /// `userChose` false for an agent's or a script's open (`cmux file open`): a markdown document
    /// is writable all the same; another document is writable only inside a root the user chose.
    /// `placed` (``LinkOpener``): a new tab opens unselected and reports its surface there, to be
    /// moved beside `pane`; a tab that already shows the file is selected and focused where it is.
    func open(_ file: URL, in pane: PaneController?, userChose: Bool, placed: (@MainActor (SurfaceID) -> Void)? = nil) -> String? {
        guard let url = AgentPaneFileOpen.resolve(file.path) else { return FilePageStrings.notAFile }
        guard let pane = pane ?? services.windows.active?.focusedPane else { return FilePageStrings.noPane }
        switch Self.kind(for: url) {
        case .markdown?:
            services.viewers.markdownPages.open(url, in: pane, focus: placed == nil, userChose: userChose, placed: placed)
        case .editor?:
            services.viewers.editorPages.open(url, in: pane, focus: placed == nil, userChose: userChose, placed: placed)
        case nil:
            guard AgentPaneFileOpen.showsInTab(url) else { return FilePageStrings.notAFile }
            pane.newBrowserTab(url: url, engine: Self.tabEngine(for: url), background: placed != nil, then: placed)
        }
        return nil
    }
}
