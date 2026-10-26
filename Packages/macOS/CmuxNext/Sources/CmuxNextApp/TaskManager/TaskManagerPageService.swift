import AppKit
import CmuxNextActions
import CmuxNextFeatures
import CmuxNextHibernation
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
/// SIGTERM through `signaler`. With `taskManagerMemorySaved` on, the page also
/// lists the pages Memory Saver discarded and what each saved.
@MainActor
final class TaskManagerPageService: InternalPageProvider {
    private weak var services: AppServices?
    let source: AppTaskManagerSource
    private let lineage: any ProcessLineage
    private let signaler: any ProcessSignaling
    private(set) var model: TaskManagerModel?

    /// Whether the page lists the discarded items and what they saved (`taskManagerMemorySaved`).
    let memorySaved: Bool
    #if DEBUG || CMUX_BENCH_HOOKS
    /// The `task-manager` capture scene's samples: the next page opens over them, the feature on.
    private var captureFixture: (any TaskManagerSampleSource)?
    #endif

    init(services: AppServices, lineage: any ProcessLineage = SystemProcessLineage(),
         signaler: any ProcessSignaling = SystemProcessSignaler()) {
        self.services = services
        let memorySaved = services.features.isEnabled(.taskManagerMemorySaved)
        self.memorySaved = memorySaved
        self.source = AppTaskManagerSource(services: services, memorySaved: memorySaved)
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
        let restored = restoredStates.removeValue(forKey: key)
        let model = self.model ?? makeModel(restoring: restored)
        self.model = model
        liveViews.insert(key)
        model.start()
        return NSHostingView(rootView: TaskManagerView(model: model))
    }

    /// A new model; a tab whose view was released gets its sort, selection and top row back.
    private func makeModel(restoring state: InternalPageViewState?) -> TaskManagerModel {
        let sampling = self.sampling
        let model = TaskManagerModel(source: sampling.source, memorySaved: sampling.memorySaved, kill: { [weak services] key in
            // The row menu and the button run the action, which asks first.
            _ = services?.registry.perform("taskManager.killProcess",
                                           invocation: ActionInvocation(arguments: ["process": .string(key.description)]))
        })
        if let state { model.restoreView(state.fields) }
        return model
    }

    func tabClosed(_ key: String) {
        restoredStates.removeValue(forKey: key)
        liveViews.remove(key)
        dropModelWhenUnused()
    }

    /// No view shows the model: sampling stops (the next view samples again).
    private func dropModelWhenUnused() {
        guard liveViews.isEmpty, let model else { return }
        model.stop()
        self.model = nil
        #if DEBUG || CMUX_BENCH_HOOKS
        captureFixture = nil
        #endif
    }

    // MARK: Discard (memory.discard.internalPages)

    /// The tabs whose view is made and not released or closed.
    private var liveViews: Set<String> = []
    /// What a tab whose view was released shows again (``restoreViewState(_:for:)``).
    private var restoredStates: [String: InternalPageViewState] = [:]

    /// The page samples every process once a second while a view shows it, so a hidden one is
    /// released after a minute; it saves its sort, selection and top row.
    var discardPolicy: InternalPageDiscardPolicy { .afterHidden(.seconds(60)) }

    func saveViewState(for key: String) -> InternalPageViewState? {
        model.map { InternalPageViewState(fields: $0.savedView) }
    }

    func restoreViewState(_ state: InternalPageViewState, for key: String) {
        restoredStates[key] = state
    }

    func viewDiscarded(_ key: String) {
        liveViews.remove(key)
        dropModelWhenUnused()
    }

    /// What the next page samples, and whether it lists the discarded items: the app's source and
    /// the feature, or the capture scene's fixture with the feature on.
    private var sampling: (source: any TaskManagerSampleSource, memorySaved: Bool) {
        #if DEBUG || CMUX_BENCH_HOOKS
        if let captureFixture { return (captureFixture, true) }
        #endif
        return (source, memorySaved)
    }

    #if DEBUG || CMUX_BENCH_HOOKS
    /// The `task-manager` capture scene: the next Task Manager page samples `fixture`, with
    /// `taskManagerMemorySaved` on. False when a page is open already (its model keeps its source).
    func useCaptureFixture(_ fixture: any TaskManagerSampleSource) -> Bool {
        guard model == nil else { return false }
        captureFixture = fixture
        return true
    }
    #endif
}
