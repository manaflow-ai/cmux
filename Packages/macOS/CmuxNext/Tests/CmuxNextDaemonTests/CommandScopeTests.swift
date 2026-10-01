import Foundation
import Testing
@testable import CmuxNextDaemon

/// The action scope behind `action.run` (plans/cmux-next/state-ownership.md 4).
@Suite struct CommandScopeTests {
    @Test func idsDeriveFromTheKeyAndOrdinalOnlyWhileOpen() {
        let first = DaemonCommandScope(idempotencyKey: "k")
        let retry = DaemonCommandScope(idempotencyKey: "k")
        let a = [first.nextMutationID(), first.nextMutationID()]
        let b = [retry.nextMutationID(), retry.nextMutationID()]
        #expect(a == b)
        #expect(a[0] != a[1])
        #expect(DaemonCommandScope(idempotencyKey: "other").nextMutationID() != a[0])
        #expect(DaemonCommandScope().nextMutationID() == nil)
        // Generated keys derive the same way, inside the scope only.
        let keys = DaemonCommandScope.$current.withValue(DaemonCommandScope(idempotencyKey: "k")) { WorkspaceKey.generate() }
        let again = DaemonCommandScope.$current.withValue(DaemonCommandScope(idempotencyKey: "k")) { WorkspaceKey.generate() }
        #expect(keys == again)
        #expect(UUID(uuidString: keys.rawValue) != nil)
        #expect(WorkspaceKey.generate() != keys)
        first.close()
        #expect(first.nextMutationID() == nil)
        #expect(first.begin() == nil)
    }

    @Test func idleWaitsForEveryTicketAndKeepsTheFirstFailure() async {
        let scope = DaemonCommandScope()
        let one = scope.begin()
        let two = scope.begin()
        #expect(!scope.isIdle)
        scope.end(one, failure: .init(label: "a", message: "a failed"))
        scope.noteBarrier(7, machine: DaemonCommandScope.localMachine)
        scope.noteBarrier(3, machine: DaemonCommandScope.localMachine)
        let waiter = Task { await scope.waitUntilIdle() }
        scope.end(two, failure: .init(label: "b", message: "b failed"))
        await waiter.value
        #expect(scope.isIdle)
        #expect(scope.failures.map(\.label) == ["a", "b"])
        #expect(scope.barrier(machine: DaemonCommandScope.localMachine) == 7)
    }

    /// `openBrowser` reports the tab it opened in `action.run`'s `created`
    /// (`cmux browser page new-tab`); before, an app browser tab was not listed.
    @Test func aNewAppBrowserTabIsReportedAsCreated() {
        let request = NewFrontendBrowserTabRequest(url: "https://cmux.com", engine: .webkit)
        let response = NewFrontendBrowserTabRequest.Response(surface: SurfaceID(rawValue: 12), tabResourceID: nil, contentResourceID: nil)
        #expect(request.createdObjects(inAny: response) == [DaemonCreatedObject(.tab, "12")])
    }

    @Test func windowRecordsKeepTheFocusedPane() throws {
        var record = WindowRecord(id: "w", selectedTabs: ["pane_1": "tab_1"])
        record.focusedPane = "pane_1"
        let data = try JSONEncoder().encode(record)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"focused_pane\":\"pane_1\""))
        let decoded = try JSONDecoder().decode(WindowRecord.self, from: data)
        #expect(decoded.focusedPane == "pane_1")
        #expect(decoded.selectedTabs == ["pane_1": "tab_1"])
    }
}
