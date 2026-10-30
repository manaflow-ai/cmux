import AppKit
import CmuxNextFiles
import CmuxNextFilesUI
import MessagesLabHome

/// Home's file host (``HomeFileHost``): a click on an attachment opens it in cmux on the right of
/// Home, never in Finder (Lawrence 2026-10-20), by ``FileOpenKind``: Markdown, web pages, images,
/// PDF, media, text and code in their viewers (``LinkOpener``); a folder in a Files pane tab; an
/// app or a document cmux cannot show selected in a Files pane tab (Open With is one right-click
/// away). The right-click menu is the shared ``FileActionsMenu``.
@MainActor
final class HomeFileActions: HomeFileHost {
    private weak var services: AppServices?
    private lazy var menu = FileActionsMenu(actions: .init(openInCmux: { [weak self] in self?.open($0) },
                                                           revealInFiles: { [weak self] in self?.reveal($0) },
                                                           openAsText: { [weak self] in self?.openAsText($0) }))

    init(services: AppServices) {
        self.services = services
    }

    func open(_ file: URL) {
        guard let services else { return }
        switch FileOpenKind(url: file) {
        case .folder?:
            try? services.viewers.filesPanes.open(folder: file, focus: true)
        case .app?, .other?:
            reveal(file)
        case .markdown?, .web?, .preview?, .editor?:
            services.linkOpener.openFile(file, from: services.windows.active?.focusedPane)
        case nil:
            break
        }
    }

    func menuItems(forFileNamed name: String, resolve: @escaping @MainActor @Sendable () async -> URL?) -> [NSMenuItem] {
        menu.items(forFileNamed: name, resolve: resolve)
    }

    /// Open as Text (u9489): the attachment's source in the code editor, on the right of Home as
    /// any open is (``LinkOpener``).
    func openAsText(_ file: URL) {
        guard let services else { return }
        services.linkOpener.openFile(file, from: services.windows.active?.focusedPane, asText: true)
    }

    private func reveal(_ file: URL) {
        try? services?.viewers.filesPanes.reveal(file, focus: true)
    }
}
