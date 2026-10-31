import AppKit
import CmuxNextAgentPane
import CmuxNextBrowser
import CmuxNextFiles
import typealias CmuxNextDaemon.SurfaceID

/// The file viewer seam (R89 ``FileOpening``) for the file pages: every file open (Open File...,
/// the cmux picker, `file.open` and `cmux file open`, Finder drops on a file page, a followed link
/// in a markdown file) comes here. Markdown files open the markdown page, other files the code
/// editor page (read only when binary or not UTF-8), in a pane tab; images, PDFs and media keep
/// the browser tab's preview, which shows them and runs nothing. A web page (HTML, SVG) opens
/// rendered in a browser tab on every open, the person's, an agent's or a script's (u18051);
/// Open as Text (`asText`) and a tab's Edit Source show its source in the editor.
final class FilePageOpener: FileOpening {
    // crash-allow: AppServices owns ViewerService, which owns this opener, for the app's whole life.
    private unowned let services: AppServices

    init(services: AppServices) {
        self.services = services
    }

    /// Raster and document previews use WebKit's scoped `loadFileURL` path. Chromium can decode a
    /// local PNG (its tab title proves the dimensions), but its sandboxed ImageDocument paints
    /// some large RGBA/color-profile files black; WebKit grants the containing folder explicitly.
    nonisolated static let webKitPreviewExtensions = FileOpenKind.previewExtensions.subtracting(AgentPaneFileOpen.mediaExtensions)

    /// The engine of the tab that previews `url`: WebKit for video and audio the Chromium build
    /// cannot decode (``LocalFileHandoff``), and for local image/PDF previews whose scoped file
    /// read and color handling are more reliable than CEF's `file://` ImageDocument.
    nonisolated static func tabEngine(for url: URL) -> String? {
        if url.localFileHandoff == .webKitTab || webKitPreviewExtensions.contains(url.pathExtension.lowercased()) {
            return BrowserEngineTag.webkit.rawValue
        }
        return nil
    }

    /// The page that opens `url`, nil for a file the browser tab previews.
    nonisolated static func kind(for url: URL) -> FilePageKind? {
        if FilePageKind.isMarkdown(url) { return .markdown }
        // Files the browser tab previews (images, PDFs, media), an explicit list (``FileOpenKind``).
        return FileOpenKind.previewExtensions.contains(url.pathExtension.lowercased()) ? nil : .editor
    }

    func open(_ file: URL, in pane: PaneController?) -> String? {
        open(file, in: pane, userChose: true)
    }

    /// Where an open of a file shows it (``route(for:userChose:asText:)``).
    enum Route: Equatable {
        /// A browser tab renders the page (HTML or SVG).
        case renderedPage
        /// The markdown page.
        case markdown
        /// The code editor page (Monaco): the file's text.
        case editor
        /// The browser tab's preview (an image, a PDF, media).
        case preview
    }

    /// The one rule for where `url` opens. `asText` (Open as Text, u9489): a page cmux renders
    /// (``FileOpenKind/opensAsText``) opens as its source in the code editor; other files open as
    /// they always do. A web page renders whoever opens it (u18051: an agent's `file.open` of an
    /// HTML report showed its source); `userChose` only decides what is writable.
    nonisolated static func route(for url: URL, userChose: Bool, asText: Bool = false) -> Route {
        let file = FileOpenKind(fileName: url.lastPathComponent, isDirectory: false, isPackage: false)
        if file.opensAsText, asText || file == .web { return asText ? .editor : .renderedPage }
        switch kind(for: url) {
        case .markdown?: return .markdown
        case .editor?: return .editor
        case nil: return .preview
        }
    }

    /// `userChose` false for an agent's or a script's open (`cmux file open`): a markdown document
    /// is writable all the same; another document is writable only inside a root the user chose.
    /// `asText`: Open as Text, the code editor for a page cmux would render (``route(for:userChose:asText:)``).
    /// `placed` (``LinkOpener``): a new tab opens unselected and reports its surface there, to be
    /// moved beside `pane`; a tab that already shows the file is selected and focused where it is.
    /// `position` (a Find result): the code editor puts the cursor there; other pages ignore it.
    func open(_ file: URL, in pane: PaneController?, userChose: Bool, asText: Bool = false, at position: FilePosition? = nil,
              placed: (@MainActor (SurfaceID) -> Void)? = nil) -> String? {
        guard let url = AgentPaneFileOpen.resolve(file.path) else { return FilePageStrings.notAFile }
        guard let pane = pane ?? services.windows.active?.focusedPane else { return FilePageStrings.noPane }
        switch Self.route(for: url, userChose: userChose, asText: asText) {
        case .renderedPage:
            pane.newBrowserTab(url: url, background: placed != nil, placementOwner: placed != nil, then: placed)
        case .markdown:
            services.viewers.markdownPages.open(url, in: pane, focus: placed == nil, userChose: userChose, placed: placed)
        case .editor:
            services.viewers.editorPages.open(url, in: pane, focus: placed == nil, userChose: userChose, at: position, placed: placed)
        case .preview:
            guard AgentPaneFileOpen.showsInTab(url) else { return FilePageStrings.notAFile }
            pane.newBrowserTab(url: url, engine: Self.tabEngine(for: url), background: placed != nil, placementOwner: placed != nil, then: placed)
        }
        return nil
    }
}
