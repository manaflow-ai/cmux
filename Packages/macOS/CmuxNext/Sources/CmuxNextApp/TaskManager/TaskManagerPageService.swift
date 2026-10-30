import AppKit
import CmuxNextActions
import CmuxNextResources
import Darwin
import SwiftUI

extension InternalPageID {
    static let taskManager = InternalPageID(rawValue: "task-manager")
}

/// The Task Manager (Window > Task Manager, `cmux app task-manager`): an
/// internal page tab, one per window, over one ``TaskManagerModel`` that
/// samples once per second while any Task Manager tab is open. Kill Process
/// (`taskManager.killProcess`) checks ``TaskManagerKillPolicy`` and sends
/// SIGTERM through `signaler`.
@MainActor
final class TaskManagerPageService: InternalPageProvider {
    private weak var services: AppServices?
    let source: AppTaskManagerSource
    private let lineage: any ProcessLineage
    private let signaler: any ProcessSignaling
    private(set) var model: TaskManagerModel?

    init(services: AppServices, lineage: any ProcessLineage = SystemProcessLineage(),
         signaler: any ProcessSignaling = SystemProcessSignaler()) {
        self.services = services
        self.source = AppTaskManagerSource(services: services)
        self.lineage = lineage
        self.signaler = signaler
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

    /// The rule Kill Process follows now.
    var killPolicy: TaskManagerKillPolicy {
        let bundle = Bundle.main.bundleURL
        let listed = model?.snapshot.rows.filter { $0.id.host == ProcessKey.localHost }.map(\.pid) ?? []
        return TaskManagerKillPolicy(appPID: getpid(), daemonPIDs: source.localDaemonPIDs,
                                     bundlePath: bundle.pathExtension == "app" ? bundle.path : nil,
                                     listedPIDs: Set(listed))
    }

    /// The process `text` names (a pid or `host:pid`), else the one selected row.
    func process(_ text: String?) -> ProcessKey? {
        if let text { return ProcessKey(parsing: text) }
        return model?.selectedRow?.id
    }

    /// Why `key` may not be ended, or nil.
    func refusal(for key: ProcessKey?) -> TaskManagerKillRefusal? {
        guard let key else { return .invalid }
        return killPolicy.refusal(for: key, lineage: lineage)
    }

    /// The question Kill Process asks for `key`.
    func prompt(for key: ProcessKey) -> TaskManagerKillPrompt {
        let listed = model?.snapshot.row(key)?.name
        let name = listed ?? lineage.executablePath(of: key.pid).map { ($0 as NSString).lastPathComponent } ?? String(key.pid)
        return TaskManagerKillPrompt(name: name, pid: key.pid)
    }

    /// Ends `key` (SIGTERM) when the policy allows it, then refreshes the page.
    func kill(_ key: ProcessKey?) throws {
        if let refusal = refusal(for: key) { throw ActionFailure(message: refusal.message) }
        guard let key, signaler.terminate(key.pid) else {
            throw ActionFailure(message: TaskManagerKillRefusal.signalFailed.message)
        }
        // task-owner: one refresh after the kill; ends when the snapshot is read
        if let model { Task { await model.refresh() } }
    }

    // MARK: InternalPageProvider

    var page: InternalPageID { .taskManager }
    var title: String { TaskManagerModel.title }
    var symbol: String { "gauge.with.dots.needle.33percent" }

    func makeView(for key: String, in window: WindowController?) -> NSView {
        let model = self.model ?? TaskManagerModel(source: source, kill: { [weak services] key in
            // The row menu and the button run the action, which asks first.
            _ = services?.registry.perform("taskManager.killProcess",
                                           invocation: ActionInvocation(arguments: ["process": .string(key.description)]))
        })
        self.model = model
        model.start()
        return NSHostingView(rootView: TaskManagerView(model: model))
    }

    func tabClosed(_ key: String) {
        guard services?.pageIsOpen(.taskManager) != true, let model else { return }
        model.stop()
        self.model = nil
    }
}
