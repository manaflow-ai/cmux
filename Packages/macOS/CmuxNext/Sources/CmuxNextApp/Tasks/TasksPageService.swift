import struct CmuxSafeConcurrency.OwnerReference
import AppKit
import CmuxNextActions
import CmuxNextHibernation
import CmuxNextSettings
import CmuxNextTasks

extension InternalPageID {
    static let tasks = InternalPageID(rawValue: "tasks")
}

/// Owns the Tasks page (plans/cmux-next/tasks.md section 14, slice 4): an
/// internal page tab (`local-page:tasks:<uuid>`, one per window) over one
/// `TasksModel` that mirrors the local team's Tasks owner through its Unix
/// socket (`SocketTasksSource`, `~/Library/Application Support/cmux/tasks/local/tasks.sock`,
/// or under `CMUX_TASKS_HOME`). The model is made on first show and
/// stopped once no tab shows it. The app does not start the owner: when
/// none answers, the pane shows how to start it (`cmux task serve`).
/// The layout follows the user setting `tasks.layout` live.
@MainActor
final class TasksPageService: InternalPageProvider {
    private let servicesReference: OwnerReference<AppServices>
    /// The app's services, which own this; nil (reported) only once they are gone.
    private var services: AppServices? { servicesReference.resolve() }
    private var sharedModel: TasksModel?
    /// A user run's scope and New Task focus made before the model exists: the model takes them
    /// when the tab first shows (``makeModel(_:)``).
    private var pendingViewState: (scope: TasksScope?, newTask: Bool)?

    init(services: AppServices) {
        servicesReference = OwnerReference(services: services)
    }

    /// The open model (debug and tests).
    var model: TasksModel? { sharedModel }

    /// Shows the Tasks tab of the active window, else opens one. `scope`
    /// (nil keeps it) and `newTask` (focus the title field) are client view
    /// state, so they apply only when `focus` is true (a user run);
    /// automation opens the tab and leaves the view as it is. A tab whose view is not made yet
    /// gets them when it first shows.
    func show(scope: TasksScope?, newTask: Bool = false, focus: Bool) throws {
        guard let services else { throw ActionFailure.appClosing }
        guard let window = services.windows.active else { throw ActionFailure(message: RefusalStrings.noWindowOpen) }
        guard services.pages.show(.tasks, in: window, focus: focus) != nil else {
            throw ActionFailure(message: RefusalStrings.noWindowOpen)
        }
        if focus, sharedModel == nil { pendingViewState = (scope, newTask) }
        Self.applyViewState(scope: scope, newTask: newTask, focus: focus, to: sharedModel)
    }

    /// The origin rule for Tasks actions: the scope and the New Task focus
    /// are client view state, so only a user run (`focus`) changes them.
    static func applyViewState(scope: TasksScope?, newTask: Bool, focus: Bool, to model: TasksModel?) {
        guard focus, let model else { return }
        if let scope { model.scope = scope }
        if newTask { model.focusNewTask() }
    }

    /// The layout the user setting asks for. Read in the pane's tracked
    /// scope, so a cmux.json change switches the layout live.
    static func layout(_ settings: SettingsController?) -> TasksLayout {
        let preference = settings?.snapshot.tasksLayout ?? TasksLayoutSetting().fallback
        return TasksLayout(rawValue: preference.rawValue) ?? TasksLayout.fallback
    }

    private func makeModel(_ services: AppServices) -> TasksModel {
        if let sharedModel { return sharedModel }
        let model = TasksModel(source: SocketTasksSource(deadlines: services.mainDeadlines))
        model.start()
        sharedModel = model
        if let pending = pendingViewState {
            pendingViewState = nil
            Self.applyViewState(scope: pending.scope, newTask: pending.newTask, focus: true, to: model)
        }
        return model
    }

    // MARK: InternalPageProvider

    var page: InternalPageID { .tasks }
    var title: String { TasksHostView.paneTitle }
    var symbol: String { "checklist" }

    func makeView(for key: String, in window: WindowController?) -> NSView {
        guard let services else { return NSView() }
        return TasksHostView(model: makeModel(services), layout: { [weak services] in Self.layout(services?.settings) })
    }

    // MARK: Discard

    /// Ten minutes hidden (Chrome's proactive_discarding_policy.cc). The scope, the selection and a
    /// New Task title typed and not sent (`newTaskDraft`) live in the shared model, which stays
    /// while the tab does, so the rebuilt view shows them; the default view state adds the scroll.
    func discardPolicy(for key: String) -> ContentDiscardPolicy { .standard }

    func tabClosed(_ key: String) {
        guard services?.pageIsOpen(.tasks) != true else { return }
        pendingViewState = nil
        guard let model = sharedModel else { return }
        model.stop()
        sharedModel = nil
    }
}
