@testable import CmuxNextTasks
import Foundation
import Testing

@MainActor
struct TasksModelTests {
    private func started(echo: Bool = true) -> (TasksModel, MockTasksSource) {
        let source = MockTasksSource()
        source.echoImmediately = echo
        let model = TasksModel(source: source)
        model.start()
        return (model, source)
    }

    @Test func intentShowsUntilSettledThenMirrorHoldsIt() {
        let (model, source) = started(echo: false)
        model.setStatus("task_3", to: "st_in_progress")
        #expect(model.pending.count == 1)
        #expect(model.visibleTasks.first { $0.id == "task_3" }?.status == "st_in_progress")
        #expect(model.confirmed["task_3"]?.status == "st_todo", "intents never write the mirror")
        source.deliverHeld()
        #expect(model.pending.isEmpty)
        #expect(model.confirmed["task_3"]?.status == "st_in_progress")
    }

    @Test func rejectRollsBackToTheMirror() {
        let (model, source) = started(echo: false)
        model.setStatus("task_3", to: "st_done")
        source.rejectKeys = Set(model.pending.map(\.key))
        source.deliverHeld()
        #expect(model.pending.isEmpty)
        #expect(model.visibleTasks.first { $0.id == "task_3" }?.status == "st_todo")
        #expect(model.lastReject != nil)
    }

    @Test func nothingQueuesWhileDisconnected() {
        let (model, source) = started()
        source.disconnect()
        #expect(model.send(.setStatus(task: "task_3", status: "st_done")) == false)
        #expect(model.pending.isEmpty)
    }

    /// Invariant 4 (projection convergence), seeded: random intents, random
    /// rejects, random delivery points; once the log is empty, visible equals
    /// the mirror.
    @Test(arguments: 0..<40)
    func convergesWhenTheIntentLogIsEmpty(seed: UInt64) {
        var rng = SplitMix(seed: seed)
        let (model, source) = started(echo: false)
        let ids = model.confirmed.keys.sorted()
        let statuses = model.statuses.map(\.id)
        for _ in 0..<30 {
            let task = ids[Int(rng.next() % UInt64(ids.count))]
            switch rng.next() % 3 {
            case 0: model.setStatus(task, to: statuses[Int(rng.next() % UInt64(statuses.count))])
            case 1: model.move(task, after: nil, before: ids.first)
            default: model.send(.create(id: "task_new\(rng.next() % 5)", title: "x", status: nil))
            }
            if rng.next() % 4 == 0, let key = model.pending.last?.key { source.rejectKeys.insert(key) }
            if rng.next() % 3 == 0 { source.deliverHeld() }
        }
        source.deliverHeld()
        #expect(model.pending.isEmpty)
        let mirror = model.confirmed.values.filter { !$0.archived && !$0.deleted }.sorted { ($0.sortKey, $0.number) < ($1.sortKey, $1.number) }
        #expect(model.visibleTasks == mirror)
    }

    @Test func decodesOwnerEventsAndFillsDerivedFields() throws {
        let (model, _) = started()
        let line = """
        {"event":{"seq":43,"index":0,"tx":"k1","at":1,"actor":{"kind":"user","id":"usr_a"},"origin":"cli","kind":"task.created",\
        "change":{"type":"upsert","value":{"entity":"task","id":"task_99","number":99,"title":"From Rust","description":{"text":"","version":1},\
        "status":"st_todo","priority":"high","assignee":null,"delegate":null,"labels":[],"project":null,"parent":null,"estimate":null,"due":null,\
        "sort_key":"zz","attention":null,"created_by":{"kind":"user","id":"usr_a"},"created_at":1,"updated_at":1,"started_at":null,\
        "completed_at":null,"canceled_at":null,"manual_status_at":null,"archived":false,"deleted":false}}}}
        """
        guard case let .event(event) = TasksWire.decode(Data(line.utf8)) else {
            Issue.record("not decoded as an event")
            return
        }
        model.handle(.event(event))
        let task = try #require(model.confirmed["task_99"])
        #expect(task.key == "CMX-99")
        #expect(task.category == .unstarted)
        #expect(model.seq == 43)
    }

    @Test func paletteComesFromTheCatalog() {
        let items = TasksPaletteCatalog.items()
        #expect(items.contains { $0.op == "task.create" && $0.title == "New Task" })
        #expect(items.contains { $0.op == "task.delegate" })
        #expect(!items.contains { $0.op == "task.list" }, "reads without a palette surface stay out")
    }

    @Test func inboxPartitionsOpenTasksExactlyOnce() {
        let (model, _) = started()
        let groups = InboxGroups(tasks: model.visibleTasks, me: "usr_lawrence")
        let all = groups.needsInput + groups.review + groups.failed + groups.mine + groups.rest
        let open = model.visibleTasks.filter { $0.category.isOpen }
        #expect(all.count == open.count)
        #expect(Set(all.map(\.id)) == Set(open.map(\.id)))
        #expect(groups.needsInput.map(\.key) == ["CMX-1"])
    }
}

/// Deterministic generator for seeded property tests.
struct SplitMix {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Review findings (MEDIUM): no reconnect, pending intents never resent;
/// settings and archived labels ignored.
@MainActor
struct TasksReconnectTests {
    @Test func pendingIntentsAreResentWithTheirKeysAfterReconnect() {
        let source = MockTasksSource()
        source.echoImmediately = false
        let model = TasksModel(source: source)
        model.start()
        model.setStatus("task_3", to: "st_done")
        let key = try? #require(model.pending.first?.key)
        source.dropHeld()
        source.disconnect()
        #expect(model.send(.archive(task: "task_4")) == false, "nothing queues while disconnected")
        source.reconnect()
        #expect(source.sentKeys.filter { $0 == key }.count == 2, "resent once, same key")
        source.deliverHeld()
        #expect(model.pending.isEmpty)
        #expect(model.confirmed["task_3"]?.status == "st_done")
    }

    @Test func settingsAndArchivedLabelsUpdateTheMirror() {
        let source = MockTasksSource()
        let model = TasksModel(source: source)
        model.start()
        model.handle(.event(TasksEvent(seq: 50, tx: "k", kind: "task.settings.updated", change: .settings(TasksSettings(keyPrefix: "ENG")))))
        #expect(model.keyPrefix == "ENG")
        model.handle(.event(TasksEvent(seq: 51, tx: "k", kind: "task.label.deleted", change: .label(TaskLabelItem(id: "lbl_bug", name: "bug", color: 1, archived: true)))))
        #expect(model.labels["lbl_bug"] == nil)
    }
}
