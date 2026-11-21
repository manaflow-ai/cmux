import AppKit
import CmuxNextActions
import CmuxNextPages
import CmuxNextResources
import CmuxNextTaskManagerPage
import Darwin

extension InternalPageID {
    static let taskManager = InternalPageID(rawValue: "task-manager")
}

/// The Task Manager (Window > Task Manager, `cmux app task-manager`): an
/// internal page tab, one per window, showing the React page
/// (webviews/src/pages/task-manager) over ``TaskManagerPages``, whose one
/// ``TaskManagerModel`` samples once per second while any Task Manager tab is
/// open. Kill Process (`taskManager.killProcess`) checks the policy and sends
/// SIGTERM through `signaler`.
@MainActor
final class TaskManagerPageService: InternalPageProvider {
    private weak var services: AppServices?
    let source: AppTaskManagerSource
    private let signaler: any ProcessSignaling
    /// The model, Kill Process's rule and every page's `cmux.task_manager.*`.
    let hub: TaskManagerPages
    private var pages: [String: PageWebView] = [:]

    init(services: AppServices, lineage: any ProcessLineage = SystemProcessLineage(),
         signaler: any ProcessSignaling = SystemProcessSignaler()) {
        self.services = services
        let source = AppTaskManagerSource(services: services)
        self.source = source
        self.signaler = signaler
        let bundle = Bundle.main.bundleURL
        hub = TaskManagerPages(source: source, lineage: lineage, appPID: getpid(),
                               bundlePath: bundle.pathExtension == "app" ? bundle.path : nil,
                               daemonPIDs: { [weak source] in source?.localDaemonPIDs ?? [] }) { [weak services] key in
            // The page's row menu and button run the action, which asks first.
            _ = services?.registry.perform("taskManager.killProcess",
                                           invocation: ActionInvocation(arguments: ["process": .string(key.description)]))
        }
    }

    /// Shows the Task Manager tab of the active window, else opens one.
    func show(focus: Bool) throws {
        guard let services, let window = services.windows.active ?? services.windows.controllers.first else {
            throw ActionFailure(message: RefusalStrings.noWindowOpen)
        }
        guard services.pages.show(.taskManager, in: window, focus: focus) != nil else {
            throw ActionFailure(message: RefusalStrings.noWindowOpen)
        }
    }

    /// Ends `key` (SIGTERM) when the policy allows it, then refreshes the page.
    func kill(_ key: ProcessKey?) throws {
        if let refusal = hub.refusal(for: key) { throw ActionFailure(message: refusal.message) }
        guard let key, signaler.terminate(key.pid) else {
            throw ActionFailure(message: TaskManagerKillRefusal.signalFailed.message)
        }
        // task-owner: one refresh after the kill; ends when the snapshot is read
        if let model = hub.model { Task { await model.refresh() } }
    }

    // MARK: InternalPageProvider

    var page: InternalPageID { .taskManager }
    var title: String { TaskManagerModel.title }
    var symbol: String { "gauge.with.dots.needle.33percent" }

    func makeView(for key: String, in window: WindowController?) -> NSView {
        hub.open()
        guard let page = PageWebView(descriptor: .taskManager, routes: [PageRoute(prefix: TaskManagerPages.prefix, provider: hub)])
        else { return NSView() }
        pages[key] = page
        return page
    }

    func tabClosed(_ key: String) {
        pages.removeValue(forKey: key)?.close()
        if services?.pageIsOpen(.taskManager) != true { hub.close() }
    }
}
