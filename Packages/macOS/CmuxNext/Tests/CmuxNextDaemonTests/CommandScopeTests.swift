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

    /// cmux-tui accepts a caller-chosen `terminal_id` only as a lowercase
    /// UUIDv4 (32 hex digits, version nibble 4, RFC 4122 variant), so an
    /// id derived inside an action run must have that shape too, or every
    /// terminal the CLI asks the app to create is refused.
    @Test func derivedTerminalIDsAreUUIDv4() {
        for key in ["k", "mutation_c0a68eeaaa94d039b434805f6b19d870", "cmux-next-new-tab-1"] {
            let scope = DaemonCommandScope(idempotencyKey: key)
            for _ in 0..<4 {
                let id = DaemonCommandScope.$current.withValue(scope) { TerminalID.generate() }.rawValue
                let bytes = Array(id.utf8)
                #expect(bytes.count == 32, "\(id)")
                #expect(id.allSatisfy { $0.isHexDigit && !$0.isUppercase }, "\(id)")
                #expect(bytes[12] == UInt8(ascii: "4"), "\(id) version")
                #expect("89ab".utf8.contains(bytes[16]), "\(id) variant")
            }
        }
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
