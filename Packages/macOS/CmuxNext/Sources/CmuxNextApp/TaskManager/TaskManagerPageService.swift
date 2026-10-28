import AppKit
import CmuxNextActions
import CmuxNextDesign
import CmuxNextFeatures
import CmuxNextHibernation
import CmuxNextResources
import CmuxNextWakeups
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
    /// The app's deadline placer: the model's wait between samples.
    private let deadlines: MainDeadlineScheduler

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
        deadlines = services.mainDeadlines
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
        // task-owner: BackgroundWork (quit skips it); one refresh after the person's kill, it ends when the snapshot
        // is read (recipe R-hop)
        if let model, let work = services?.work { work.task(.userBlocking) { await model.refresh() } }
    }

    // MARK: InternalPageProvider

    var page: InternalPageID { .taskManager }
    var title: String { TaskManagerModel.title }
    var symbol: String { "gauge.with.dots.needle.33percent" }

    func makeView(for key: String, in window: WindowController?) -> NSView {
        let sampling = self.sampling
        let model = self.model ?? TaskManagerModel(source: sampling.source, deadlines: deadlines,
                                                   memorySaved: sampling.memorySaved, kill: { [weak services] key in
            // The row menu and the button run the action, which asks first.
            _ = services?.registry.perform("taskManager.killProcess",
                                           invocation: ActionInvocation(arguments: ["process": .string(key.description)]))
        })
        self.model = model
        let table = tables[key] ?? TaskManagerTableState()
        tables[key] = table
        liveViews.insert(key)
        model.start()
        return VisibilityGatedHostingView(owner: "TaskManagerPage") { TaskManagerView(model: model, table: table) }
    }

    func tabClosed(_ key: String) {
        tables.removeValue(forKey: key)
        liveViews.remove(key)
        dropModelWhenUnused()
    }

    /// No view shows the model: sampling stops (the next view samples again). A discarded tab has
    /// no view, so it keeps no sampling running.
    private func dropModelWhenUnused() {
        guard liveViews.isEmpty, let model else { return }
        model.stop()
        self.model = nil
        #if DEBUG || CMUX_BENCH_HOOKS
        captureFixture = nil
        #endif
    }

    /// The tabs whose view is made and not discarded or closed.
    private(set) var liveViews: Set<String> = []
    /// Each tab's table (its sort and the row it scrolls back to), kept while the tab is open.
    private(set) var tables: [String: TaskManagerTableState] = [:]

    // MARK: Discard (`memoryDiscardInternalPages`)

    /// One minute hidden: a view samples every cmux process once a second while it exists.
    func discardPolicy(for key: String) -> ContentDiscardPolicy { .afterHidden(.seconds(60)) }

    /// The tab's sort, and the row at the top of its table.
    func saveViewState(for key: String, content: NSView) async -> ContentViewState {
        guard let table = tables[key] else { return ContentViewState() }
        var state = ContentViewState(values: ["sort": table.sort])
        let rows = model.map { table.rows(of: $0.snapshot) } ?? []
        state.values["topRow"] = Self.topRow(in: content, rows: rows)?.description
        return state
    }

    /// Sorts as before and scrolls the saved top row back to the top once a sample lists it.
    func restoreViewState(_ state: ContentViewState, for key: String, content: NSView) async {
        guard let table = tables[key] else { return }
        table.sortOrder = TaskManagerSort.order(state.values["sort"] ?? table.sort)
        table.scrollTarget = state.values["topRow"].flatMap(ProcessKey.init(parsing:))
    }

    /// The tab's view went; its table stays for the next view. The last view gone stops sampling.
    func viewDiscarded(_ key: String) {
        liveViews.remove(key)
        dropModelWhenUnused()
    }

    /// The row of `rows` (in the table's order) drawn at the top of the table in `content`; nil
    /// with no table or no row there.
    static func topRow(in content: NSView, rows: [TaskManagerRow]) -> ProcessKey? {
        var queue: [NSView] = [content]
        var index = 0
        while index < queue.count {
            let next = queue[index]
            index += 1
            if let scroll = next as? NSScrollView, let tableView = scroll.documentView as? NSTableView {
                // The clip's bounds start above the document by its top inset (the header) at the top.
                let clip = scroll.contentView
                let top = NSPoint(x: clip.bounds.minX, y: max(0, clip.bounds.minY + clip.contentInsets.top))
                let row = tableView.row(at: top)
                return rows.indices.contains(row) ? rows[row].id : nil
            }
            queue.append(contentsOf: next.subviewsIncludingGated)
        }
        return nil
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
