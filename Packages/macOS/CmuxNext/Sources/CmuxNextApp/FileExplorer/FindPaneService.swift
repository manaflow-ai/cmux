import AppKit
import CmuxNextActions
import CmuxNextFilesUI
import CmuxNextHibernation
import CmuxNextPages
import CmuxNextWakeups

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
    private let mainWork: MainWorkScheduler
    private var views: [String: FindSectionView] = [:]
    private var roots: [String: URL] = [:]
    /// The folder each ``open(folder:focus:)`` asked for, for the tab it opened.
    private let opens = PageOpenRequests<URL>()

    init(services: AppServices?, mainWork: MainWorkScheduler) {
        self.services = services
        self.mainWork = mainWork
    }

    var page: InternalPageID { .findPane }
    var title: String { FileExplorerStrings.findTitle }
    var symbol: String { "text.magnifyingglass" }

    func route(for key: String) -> String? { (views[key]?.model.root ?? roots[key] ?? opens.kept(for: key))?.path }

    func restore(_ route: String, for key: String) {
        guard route.hasPrefix("/") else { return }
        roots[key] = URL(fileURLWithPath: route, isDirectory: true)
    }

    /// Opens a new Find tab on `folder` (home when nil) after the active window's focused tab.
    func open(folder: URL?, focus: Bool) throws {
        guard let services, let window = services.windows.active else { throw ActionFailure(message: RefusalStrings.noWindowOpen) }
        guard let view = opens.open(folder, { services.pages.openNew(.findPane, in: window, focus: focus) }) else {
            throw ActionFailure(message: RefusalStrings.noWindowOpen)
        }
        // A focused open shows the tab, so it makes the tab's view now.
        if focus, let find = view.content as? FindSectionView { view.window?.makeFirstResponder(find.field) }
    }

    func makeView(for key: String, in window: WindowController?) -> NSView {
        let asked = opens.take(for: key)
        let folder = roots[key] ?? asked ?? opens.running ?? FileManager.default.homeDirectoryForCurrentUser
        roots[key] = folder
        let effects = services?.fileExplorers.effects ?? NullFileExplorerEffects()
        let view = FindSectionView(model: FindSectionModel(), mainWork: mainWork, rootFolder: { [weak self] in
            self?.roots[key] ?? folder
        }, effects: effects)
        views[key] = view
        return view
    }

    func tabClosed(_ key: String) {
        views.removeValue(forKey: key)
        roots.removeValue(forKey: key)
        opens.forget(key)
    }

    // MARK: Discard (`memoryDiscardInternalPages`)

    /// Ten minutes hidden, as Chrome's proactive discards (proactive_discarding_policy.cc). The view
    /// and its results go; the query and the selected result are saved, and the next view searches
    /// the tab's folder again (Chrome reloads a discarded tab) and selects that result.
    func discardPolicy(for key: String) -> ContentDiscardPolicy { .standard }

    func saveViewState(for key: String, content: NSView) async -> ContentViewState {
        guard let view = content as? FindSectionView else { return ContentViewState() }
        return ContentViewState(scroll: view.resultsScroll, search: view.field.stringValue, selection: view.cursor)
    }

    func restoreViewState(_ state: ContentViewState, for key: String, content: NSView) async {
        guard let view = content as? FindSectionView, let query = state.search, !query.isEmpty else { return }
        view.restore(query: query, cursor: state.selection, scroll: state.scroll)
    }

    /// The tab keeps its folder (``route(for:)``) for the next view.
    func viewDiscarded(_ key: String) {
        views.removeValue(forKey: key)
    }
}
