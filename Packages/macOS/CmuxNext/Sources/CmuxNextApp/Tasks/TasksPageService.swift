import AppKit
import CmuxNextActions
import CmuxNextCompat
import CmuxNextPages
import CmuxNextSettings

extension InternalPageID {
    static let tasks = InternalPageID(rawValue: "tasks")
}

/// Owns the Tasks page (plans/cmux-next/tasks.md section 14): an internal page tab
/// (`local-page:tasks:<uuid>`, one per window) showing the React page (webviews/src/pages/tasks),
/// which reads and changes tasks through the daemon. Swift only hosts it, sets its route (scope,
/// New Task) on a user run, and keeps `data-tasks-layout` on its `<html>` equal to the user
/// setting `tasks.layout`. The app does not start the owner: when none answers, the page shows
/// how to start it (`cmux task serve`).
@MainActor
final class TasksPageService: InternalPageProvider {
    private unowned let services: AppServices
    /// The open pages, for the layout setting.
    private let pages = NSHashTable<PageWebView>.weakObjects()
    private var layoutObservation: Task<Void, Never>?
    /// Bumped by every user-run New Task, so the route changes and the page focuses its field.
    private var newTaskRequest = 0

    init(services: AppServices) {
        self.services = services
    }

    /// Shows the Tasks tab of the active window, else opens one. `scope` (the page's route path:
    /// `all`, or `mine` for My Tasks; nil keeps it) and
    /// `newTask` (focus the title field) are client view state, so they apply only when `focus`
    /// is true (a user run); automation opens the tab and leaves the view as it is.
    func show(scope: String?, newTask: Bool = false, focus: Bool) throws {
        guard let window = services.windows.active, let view = services.pages.show(.tasks, in: window, focus: focus) else {
            throw ActionFailure(message: RefusalStrings.noWindowOpen)
        }
        guard focus, scope != nil || newTask else { return }
        if newTask { newTaskRequest += 1 }
        let route = "/\(scope ?? "")" + (newTask ? "?new=\(newTaskRequest)" : "")
        (view.content as? PageWebView)?.open(route: route)
    }

    /// The layout the user setting asks for (`list`, `board`, `inbox`).
    static func layout(_ settings: SettingsController?) -> String {
        (settings?.snapshot.tasksLayout ?? TasksLayoutSetting().fallback).rawValue
    }

    /// Follows `tasks.layout` into every open page; ends at the first change after the last closes.
    private func followLayout() {
        guard layoutObservation == nil, let settings = services.settings else { return }
        // task-owner: lives while a Tasks page is open; event-driven (Observation)
        layoutObservation = Task { [weak self] in
            for await layout in ObservationStream({ Self.layout(settings) }) {
                guard let self, !pages.allObjects.isEmpty else { break }
                for page in pages.allObjects { page.setDocumentAttribute("tasks-layout", layout) }
            }
            self?.layoutObservation = nil
        }
    }

    // MARK: InternalPageProvider

    var page: InternalPageID { .tasks }
    var title: String { String(localized: "tasks.page.title", defaultValue: "Tasks", table: "Tasks", bundle: .module) }
    var symbol: String { "checklist" }

    func makeView(for key: String, in window: WindowController?) -> NSView {
        let routes = PageFactory(services: services).pageRoutes(for: .tasks)
        guard let page = PageWebView(descriptor: .tasks, routes: routes,
                                     documentAttributes: ["tasks-layout": Self.layout(services.settings)]) else { return NSView() }
        PageConnectionWatch(page: page, store: services.machines.local.store).start()
        pages.add(page)
        followLayout()
        return page
    }
}
