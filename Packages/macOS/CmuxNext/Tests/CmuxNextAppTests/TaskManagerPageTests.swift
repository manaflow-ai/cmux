@testable import CmuxNextApp
import CmuxNextPages
import CmuxNextResources
import CmuxNextSettings
import CmuxNextTaskManagerPage
import Foundation
import Testing

/// The Task Manager's React page transport (``TaskManagerPages``):
/// what a `snapshot` event holds (the rows the SwiftUI table showed, with the app's own number text
/// and the policy's refusal per row), that the model hands each sample to the page, and that `kill`
/// runs only on the person's gesture, once per gesture. The page's sorting and selection are
/// webviews/test/task-manager-store.test.ts.
@MainActor @Suite(.serialized)
struct TaskManagerPageTests {
    static let policy = TaskManagerKillPolicy(appPID: 100, daemonPIDs: [200], bundlePath: "/Applications/cmux.app")

    static func rows(_ payload: JSONValue) -> [[String: JSONValue]] {
        (payload["rows"]?.arrayValue ?? []).compactMap(\.objectValue)
    }

    @Test func aSnapshotEventHasEveryColumnAndTheRefusalPerRow() throws {
        let snapshot = TaskManagerSnapshot(current: TaskManagerSnapshotTests.set(at: 2, cpu: 2),
                                           previous: TaskManagerSnapshotTests.set(at: 1, cpu: 1))
        let payload = TaskManagerPages.payload(snapshot, revision: 7, policy: Self.policy)
        #expect(payload["revision"]?.intValue == 7)
        #expect(payload["total"]?.stringValue == ResourceFormat.line(snapshot.total))
        let rows = Self.rows(payload)
        #expect(rows.compactMap { $0["id"]?.stringValue } == ["local:100", "local:200", "local:300", "local:400", "local:500", "m-1:400"],
                "the app's order, ids as ProcessKey text")
        let shell = try #require(rows.first { $0["id"]?.stringValue == "local:400" })
        let row = try #require(snapshot.row(TaskManagerSnapshotTests.shell))
        #expect(shell["pid"]?.intValue == 400)
        #expect(shell["host"]?.stringValue == "local")
        #expect(shell["task"]?.stringValue == row.task)
        #expect(shell["name"]?.stringValue == row.name)
        #expect(shell["cpuText"]?.stringValue == ResourceFormat.cpu(row.cpu ?? -1))
        #expect(shell["memoryText"]?.stringValue == ResourceFormat.memory(row.memoryBytes))
        #expect(shell["memoryBytes"] == .number(Double(row.memoryBytes)))
        #expect(shell["refusal"] == .null, "a tab's process may be ended")
        let refusal = { (id: String) in rows.first { $0["id"]?.stringValue == id }?["refusal"]?.stringValue }
        #expect(refusal("local:100") == TaskManagerKillRefusal.appProcess.message)
        #expect(refusal("local:200") == TaskManagerKillRefusal.daemonProcess.message)
        #expect(refusal("m-1:400") == TaskManagerKillRefusal.remoteHost.message)
    }

    @Test func theFirstSampleHasNoCPU() {
        let snapshot = TaskManagerSnapshot(current: TaskManagerSnapshotTests.set(at: 1, cpu: 1), previous: nil)
        let rows = Self.rows(TaskManagerPages.payload(snapshot, revision: 1, policy: Self.policy))
        #expect(rows.allSatisfy { $0["cpu"] == .null })
        #expect(Set(rows.compactMap { $0["cpuText"]?.stringValue }).count == 1, "every row shows the pending dash")
    }

    @Test func listedRefusalMatchesThePolicyForListedRows() {
        let policy = TaskManagerKillPolicy(appPID: 100, daemonPIDs: [200], bundlePath: "/Applications/cmux.app", listedPIDs: [212, 400])
        for pid: Int32 in [100, 200, 212, 400] {
            let key = ProcessKey(pid: pid)
            #expect(policy.listedRefusal(for: key) == policy.refusal(for: key, lineage: TaskManagerSnapshotTests.table), "pid \(pid)")
        }
        #expect(policy.listedRefusal(for: TaskManagerSnapshotTests.remote) == .remoteHost)
        #expect(policy.listedRefusal(for: ProcessKey(pid: 1)) == .notCmuxProcess)
    }

    @Test func theModelHandsEachSampleToThePage() async {
        let source = TaskManagerSnapshotTests.Source()
        let model = TaskManagerModel(source: source, kill: { _ in })
        var seen: [Int] = []
        model.onSnapshot = { seen.append($0.rows.count) }
        await model.refresh()
        await model.refresh()
        #expect(seen == [6, 6])
    }

    /// A hub over the synthetic samples; `killed` records what Kill Process was asked to end.
    @MainActor final class Hub {
        let source = TaskManagerSnapshotTests.Source()
        var killed: [ProcessKey] = []
        lazy var pages = TaskManagerPages(source: source, lineage: TaskManagerSnapshotTests.table, appPID: 100,
                                          daemonPIDs: { [200] }) { [unowned self] in killed.append($0) }
    }

    @Test func killRunsOnlyOnAFreshGesture() async throws {
        let hub = Hub()
        let provider = hub.pages
        provider.open()
        defer { provider.close() }
        let op = TaskManagerPages.prefix + "kill"
        let page = PageDescriptor.taskManager.id
        func code(_ context: PageCallContext, _ id: String = "local:4242") async -> String? {
            do {
                _ = try await provider.call(op, params: ["id": .string(id)], context: context)
                return nil
            } catch let error as PageError {
                return error.code
            } catch {
                return "other"
            }
        }
        #expect(await code(PageCallContext(page: page)) == PageNativeOp.userOnlyCode, "page script alone")
        #expect(await code(PageCallContext(page: page, userGesture: true, gestureEvent: 5), "not-a-pid") != nil)
        #expect(await code(PageCallContext(page: page, userGesture: true, gestureEvent: 5)) == nil)
        #expect(await code(PageCallContext(page: page, userGesture: true, gestureEvent: 5)) == PageNativeOp.userOnlyCode,
                "a gesture is spent by one kill")
        #expect(await code(PageCallContext(page: page, userGesture: true, gestureEvent: 6)) == nil)
        #expect(hub.killed == [ProcessKey(pid: 4242), ProcessKey(pid: 4242)], "each fresh gesture runs the action once")
    }

    @Test func theStreamSendsWhatThePageShowsAtOnceAndSelectKeepsListedRows() async throws {
        let hub = Hub()
        let provider = hub.pages
        var events: [JSONValue] = []
        let subscription = try await provider.subscribe(TaskManagerPages.prefix + "snapshot", filter: [:],
                                                        context: PageCallContext(page: PageDescriptor.taskManager.id)) { events.append($0) }
        defer { subscription.cancel() }
        #expect(events.count == 1)
        #expect(events.first?["revision"]?.intValue == 0)
        #expect(Self.rows(events[0]).isEmpty)
        _ = try await provider.call(TaskManagerPages.prefix + "select", params: ["ids": ["local:4242"]],
                                    context: PageCallContext(page: PageDescriptor.taskManager.id))
        #expect(provider.model == nil, "no open page: nothing to select, nothing sampled")
        let model = provider.open()
        await model.refresh()
        #expect(events.count >= 2, "a sample reaches the open page")
        _ = try await provider.call(TaskManagerPages.prefix + "select", params: ["ids": ["local:400", "local:4242"]],
                                    context: PageCallContext(page: PageDescriptor.taskManager.id))
        #expect(model.selection == [TaskManagerSnapshotTests.shell], "only listed rows are selected")
        #expect(provider.process(nil) == TaskManagerSnapshotTests.shell, "kill-process with no pid takes the selected row")
        #expect(provider.refusal(for: ProcessKey(pid: 100)) == .appProcess)
        provider.close()
        #expect(provider.model == nil && !model.isRunning, "the last page closed: sampling stops")
    }

    /// Two windows' pages: a `select` from either reaches both streams with the one selection the
    /// provider holds, so a page never shows a row other than the one Kill Process and the CLI end.
    @Test func selectBroadcastsTheOneSelectionToEveryOpenPage() async throws {
        let hub = Hub()
        let provider = hub.pages
        let context = PageCallContext(page: PageDescriptor.taskManager.id)
        var first: [JSONValue] = []
        var second: [JSONValue] = []
        let one = try await provider.subscribe(TaskManagerPages.prefix + "snapshot", filter: [:], context: context) { first.append($0) }
        let two = try await provider.subscribe(TaskManagerPages.prefix + "snapshot", filter: [:], context: context) { second.append($0) }
        defer { one.cancel(); two.cancel() }
        #expect(first.last?["selected"] == .null && second.last?["selected"] == .null, "nothing selected yet")
        let model = provider.open()
        defer { provider.close() }
        await model.refresh()
        let other = ProcessKey(pid: 300)
        func select(_ key: ProcessKey) async throws {
            _ = try await provider.call(TaskManagerPages.prefix + "select", params: ["ids": [.string(key.description)]], context: context)
        }
        try await select(TaskManagerSnapshotTests.shell)
        try await select(other)
        let before = (first.count, second.count)
        try await select(TaskManagerSnapshotTests.shell)
        #expect(first.count > before.0 && second.count > before.1, "the select reaches each page, not only the one that sent it")
        #expect(first.last?["selected"]?.stringValue == TaskManagerSnapshotTests.shell.description)
        #expect(second.last?["selected"]?.stringValue == TaskManagerSnapshotTests.shell.description)
        #expect(provider.process(nil) == TaskManagerSnapshotTests.shell, "kill-process with no pid takes what both pages show")
        await model.refresh()
        #expect(second.last?["selected"]?.stringValue == TaskManagerSnapshotTests.shell.description, "a sample keeps it")
    }

    @Test func thePageIsShippedAndAdmitsOnlyItsNamespace() {
        #expect(FirstPartyPageSchemes.descriptors.contains(.taskManager))
        #expect(PageDescriptor.taskManager.admits("cmux.task_manager.kill"))
        #expect(!PageDescriptor.taskManager.admits(PageNativeOp.actionRun))
    }
}
