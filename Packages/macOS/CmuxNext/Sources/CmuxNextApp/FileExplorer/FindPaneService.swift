import AppKit
import CmuxNextActions
import CmuxNextFilesUI

extension InternalPageID {
    /// Open Find as Pane: the right sidebar's Find section in a tab.
    nonisolated static let findPane = InternalPageID(rawValue: "find-pane")
}

/// Find tabs (Open Find as Pane, classic's right sidebar Find tool as a pane):
/// one ``FindSectionView`` per tab over the folder the focused terminal showed
/// when it opened. The tab's route is that folder, so a reopened or relaunched
/// tab searches it again.
@MainActor
final class FindPaneService: InternalPageProvider {
    private weak var services: AppServices?
    private var views: [String: FindSectionView] = [:]
    private var roots: [String: URL] = [:]
    /// The folder the next new tab searches (``open(folder:focus:)``).
    private var pendingFolder: URL?

    init(services: AppServices?) {
        self.services = services
    }

    var page: InternalPageID { .findPane }
    var title: String { FileExplorerStrings.findTitle }
    var symbol: String { "text.magnifyingglass" }

    func route(for key: String) -> String? { (views[key]?.model.root ?? roots[key])?.path }

    func restore(_ route: String, for key: String) {
        guard route.hasPrefix("/") else { return }
        roots[key] = URL(fileURLWithPath: route, isDirectory: true)
    }

    /// Opens a new Find tab on `folder` (home when nil) after the active window's focused tab.
    func open(folder: URL?, focus: Bool) throws {
        guard let services, let window = services.windows.active else { throw ActionFailure(message: RefusalStrings.noWindowOpen) }
        pendingFolder = folder
        defer { pendingFolder = nil }
        guard let view = services.pages.openNew(.findPane, in: window, focus: focus) else {
            throw ActionFailure(message: RefusalStrings.noWindowOpen)
        }
        if focus, let find = view.content as? FindSectionView { view.window?.makeFirstResponder(find.field) }
    }

    func makeView(for key: String, in window: WindowController?) -> NSView {
        let folder = roots[key] ?? pendingFolder ?? FileManager.default.homeDirectoryForCurrentUser
        roots[key] = folder
        let effects = services?.fileExplorers.effects ?? NullFileExplorerEffects()
        let view = FindSectionView(model: FindSectionModel(), rootFolder: { [weak self] in
            self?.roots[key] ?? folder
        }, effects: effects)
        views[key] = view
        return view
    }

    func tabClosed(_ key: String) {
        views.removeValue(forKey: key)
        roots.removeValue(forKey: key)
    }
}
