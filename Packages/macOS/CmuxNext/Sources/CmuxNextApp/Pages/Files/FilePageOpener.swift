import AppKit
import CmuxNextAgentPane

/// The file viewer seam (R89 ``FileOpening``) for the file pages: every file open (Open File...,
/// the cmux picker, `file.open` and `cmux file open`, Finder drops on a file page, a followed link
/// in a markdown file) comes here. Markdown files open the markdown page, other files the code
/// editor page (read only when binary or not UTF-8), in a pane tab; images, PDFs and media keep
/// the browser tab's preview, which shows them and runs nothing.
final class FilePageOpener: FileOpening {
    private unowned let services: AppServices

    init(services: AppServices) {
        self.services = services
    }

    /// Files the browser tab previews (images, PDFs, media). An explicit list, because the system
    /// types `.ts` (TypeScript) as an MPEG transport stream.
    nonisolated static let previewExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp", "ico", "avif", "pdf",
        "mp4", "mov", "m4v", "webm", "mp3", "m4a", "wav", "aac", "flac", "ogg",
    ]

    /// The page that opens `url`, nil for a file the browser tab previews.
    nonisolated static func kind(for url: URL) -> FilePageKind? {
        if FilePageKind.isMarkdown(url) { return .markdown }
        return previewExtensions.contains(url.pathExtension.lowercased()) ? nil : .editor
    }

    func open(_ file: URL, in pane: PaneController?) -> String? {
        guard let url = AgentPaneFileOpen.resolve(file.path) else { return FilePageStrings.notAFile }
        guard let pane = pane ?? services.windows.active?.focusedPane else { return FilePageStrings.noPane }
        switch Self.kind(for: url) {
        case .markdown?:
            services.markdownPages.open(url, in: pane, focus: true)
        case .editor?:
            services.editorPages.open(url, in: pane, focus: true)
        case nil:
            guard AgentPaneFileOpen.showsInTab(url) else { return FilePageStrings.notAFile }
            pane.newBrowserTab(url: url)
        }
        return nil
    }
}
