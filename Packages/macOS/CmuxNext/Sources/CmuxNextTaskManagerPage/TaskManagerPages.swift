public import CmuxNextPages
public import CmuxNextResources
public import CmuxNextSettings
public import Foundation

public extension PageDescriptor {
    /// The Task Manager page (webviews/src/pages/task-manager): cmux's processes with CPU and memory,
    /// one tab per window. It reads the `snapshot` stream and calls `select` and `kill`; nothing else.
    static let taskManager = PageDescriptor(id: "cmux.task-manager", resource: "task-manager",
                                            namespaces: [TaskManagerPages.prefix])
}

/// The Task Manager's one ``TaskManagerModel`` (sampling once per second while a page is open,
/// ``open()`` to ``close()``), Kill Process's rule over it, and every open page's
/// `cmux.task_manager.*` (the App routes each page's namespace here):
///
/// - stream `snapshot`: ``payload(_:revision:policy:selected:)`` at once, then after every sample and
///   every `select`, so each open page shows the one selection this provider holds;
/// - `select {ids}`: the selected rows (``ProcessKey`` text), for `cmux app kill-process` with no pid.
///   Every open page hears the new selection, so Kill Process and the CLI end what every page shows;
/// - `kill {id}`: Kill Process for one row, only on the person's own click, key or menu choice in the
///   page (a gesture no earlier kill spent). It runs `kill`, the App's `taskManager.killProcess`,
///   which checks ``TaskManagerKillPolicy`` and asks first, as the palette and the CLI do.
///
/// ```swift
/// let pages = TaskManagerPages(source: source, appPID: getpid(), daemonPIDs: { [] }, kill: { _ in })
/// let model = pages.open()
/// ```
@MainActor
public final class TaskManagerPages: PageProvider {
    public static let prefix = "cmux.task_manager."

    public private(set) var model: TaskManagerModel?
    private let source: any TaskManagerSampleSource
    private let lineage: any ProcessLineage
    private let appPID: Int32
    private let bundlePath: String?
    private let daemonPIDs: @MainActor () -> Set<Int32>
    private let killAction: @MainActor (ProcessKey) -> Void
    private var listeners: [UUID: @MainActor (JSONValue) -> Void] = [:]
    /// The gesture the last kill spent (`PageCallContext.gestureEvent`).
    private var spentGesture: TimeInterval?

    /// - Parameters:
    ///   - source: Takes the samples (the model holds it weakly; the App owns it).
    ///   - bundlePath: The app bundle, for ``TaskManagerKillPolicy/bundlePath``; nil skips that rule.
    ///   - daemonPIDs: This Mac's connected daemons now.
    ///   - kill: Kill Process for one process (the action, which asks first).
    public init(source: any TaskManagerSampleSource, lineage: any ProcessLineage = SystemProcessLineage(), appPID: Int32,
                bundlePath: String? = nil, daemonPIDs: @escaping @MainActor () -> Set<Int32>,
                kill: @escaping @MainActor (ProcessKey) -> Void) {
        self.source = source
        self.lineage = lineage
        self.appPID = appPID
        self.bundlePath = bundlePath
        self.daemonPIDs = daemonPIDs
        self.killAction = kill
    }

    /// A page opened: the model, sampling (made on the first page).
    @discardableResult
    public func open() -> TaskManagerModel {
        let model = self.model ?? TaskManagerModel(source: source, kill: killAction)
        self.model = model
        model.onSnapshot = { [weak self] _ in self?.publish() }
        model.start()
        return model
    }

    /// The last page closed: sampling stops and the model goes.
    public func close() {
        model?.stop()
        model?.onSnapshot = nil
        model = nil
    }

    /// The rule Kill Process follows now: the last sample's local rows are listed.
    public var killPolicy: TaskManagerKillPolicy {
        let listed = model?.snapshot.rows.filter { $0.id.host == ProcessKey.localHost }.map(\.pid) ?? []
        return TaskManagerKillPolicy(appPID: appPID, daemonPIDs: daemonPIDs(), bundlePath: bundlePath, listedPIDs: Set(listed))
    }

    /// The process `text` names (a pid or `host:pid`), else the one selected row.
    public func process(_ text: String?) -> ProcessKey? {
        if let text { return ProcessKey(parsing: text) }
        return model?.selectedRow?.id
    }

    /// Why `key` may not be ended, or nil.
    public func refusal(for key: ProcessKey?) -> TaskManagerKillRefusal? {
        guard let key else { return .invalid }
        return killPolicy.refusal(for: key, lineage: lineage)
    }

    /// The question Kill Process asks for `key`.
    public func prompt(for key: ProcessKey) -> TaskManagerKillPrompt {
        let listed = model?.snapshot.row(key)?.name
        let name = listed ?? lineage.executablePath(of: key.pid).map { ($0 as NSString).lastPathComponent } ?? String(key.pid)
        return TaskManagerKillPrompt(name: name, pid: key.pid)
    }

    // MARK: The pages' stream and calls

    /// What a page shows now.
    public var payload: JSONValue {
        Self.payload(model?.snapshot ?? .empty, revision: model?.sampleCount ?? 0, policy: killPolicy,
                     selected: model?.selectedRow?.id)
    }

    /// The `snapshot` event of `snapshot`: `{revision, rows, total, selected}`. A row is `{id, host, pid, task,
    /// name, cpu, cpuText, memoryBytes, memoryText, refusal}`; `id` is ``ProcessKey`` text
    /// (`local:4242`), `cpu` null until a second sample, and `refusal` the reason the policy will
    /// not end the row's process (``TaskManagerKillPolicy/listedRefusal(for:)``), else null, so the
    /// page greys out Kill Process. `total` is the footer's numbers (`CPU 2.3% · Memory 145.2 MB`).
    /// `selected` is the one selected row's id (``TaskManagerModel/selectedRow``), else null: the
    /// selection every page shows and Kill Process and `cmux app kill-process` act on.
    public static func payload(_ snapshot: TaskManagerSnapshot, revision: Int, policy: TaskManagerKillPolicy,
                               selected: ProcessKey? = nil) -> JSONValue {
        let rows: [JSONValue] = snapshot.rows.map { row in
            .object([
                "id": .string(row.id.description),
                "host": .string(row.id.host),
                "pid": JSONValue(Int(row.pid)),
                "task": .string(row.task),
                "name": .string(row.name),
                "cpu": row.cpu.map(JSONValue.number) ?? .null,
                "cpuText": .string(row.cpuText),
                "memoryBytes": .number(Double(row.memoryBytes)),
                "memoryText": .string(row.memoryText),
                "refusal": policy.listedRefusal(for: row.id).map { JSONValue.string($0.message) } ?? .null,
            ])
        }
        return .object([
            "revision": JSONValue(revision),
            "rows": .array(rows),
            "total": .string(ResourceFormat.line(snapshot.total)),
            "selected": selected.map { JSONValue.string($0.description) } ?? .null,
        ])
    }

    private func publish() {
        guard !listeners.isEmpty else { return }
        let payload = payload
        for listener in listeners.values { listener(payload) }
    }

    public func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        switch op {
        case Self.prefix + "select":
            guard let ids = params["ids"]?.arrayValue else { throw PageError.invalidParams("ids must be an array of process ids") }
            if let model {
                let listed = Set(model.snapshot.rows.map(\.id))
                model.selection = Set(ids.compactMap(\.stringValue).compactMap(ProcessKey.init(parsing:))).intersection(listed)
                publish()
            }
            return .object([:])
        case Self.prefix + "kill":
            guard context.userGesture, let event = context.gestureEvent, event != spentGesture else {
                throw PageError(code: PageNativeOp.userOnlyCode, message: "Kill Process runs only on a click or key in the page")
            }
            guard let text = params["id"]?.stringValue, let key = ProcessKey(parsing: text) else {
                throw PageError.invalidParams("id must be a process id, such as local:4242")
            }
            spentGesture = event
            model?.kill(key)
            return .object([:])
        default:
            throw PageError.unknownOp(op)
        }
    }

    /// An open page's `snapshot` stream: what it shows now at once, then every sample.
    public func subscribe(_ stream: String, filter: JSONValue, context: PageCallContext,
                          onEvent: @escaping @MainActor (JSONValue) -> Void) async throws -> PageSubscription {
        guard stream == Self.prefix + "snapshot" else { throw PageError.unknownOp(stream) }
        let id = UUID()
        listeners[id] = onEvent
        onEvent(payload)
        return PageSubscription { [weak self] in self?.listeners[id] = nil }
    }
}
