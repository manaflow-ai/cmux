@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextPages
import CmuxNextSettings
import CmuxNextWakeups
import Foundation
import Testing

/// Page-relay person cause (p06-scheduler-231, p06-scheduler.md "Page relay"): page calls pass
/// through the app (router, ``DaemonPageRelay``, ``PageRelayChannel``), so a mutation a page sends
/// within 1 s of a real key or pointer event in that page has its idempotency key, which the daemon
/// echoes as the delta's `mutation_id`, recorded as `person` on the main connection that hears the
/// echo. Without a gesture the echo keeps the daemon's cause for a page, `automation`. Runs on the
/// production router, relay and channel over the fake relay socket of ``PageRelayChannelFreezeTests``.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1))) struct PageRelayPersonCauseTests {
    private typealias Rig = PageRelayChannelFreezeTests.Rig

    /// The daemon's echo of a page relay mutation: a workspace delta whose `mutation_id` is the key.
    private static func echo(_ key: String) -> DaemonEvent {
        let handle = WorkspaceHandle(rawValue: 1)
        return .workspaceChanged(WorkspaceDelta(workspace: handle, index: nil,
                                                entity: WorkspaceSnapshot(id: handle, key: WorkspaceKey(rawValue: "w"), name: "n"),
                                                workspaceRevision: 2, mutationID: key))
    }

    /// Sends `op` through the page's router, as the page's bridge does, with `opid`.
    private static func call(_ page: PageRelayChannelFreezeTests.Page, _ op: String, opid: String,
                             params: CmuxNextSettings.JSONValue = .object([:])) async throws {
        let reply = await page.router.handle(["t": "call", "id": 1, "op": .string(op), "opid": .string(opid), "params": params])
        try #require(reply["t"]?.stringValue == "ok", "\(reply)")
    }

    private static func ledger(_ rig: Rig) throws -> MutationCauseLedger {
        try #require(rig.daemon.connection).mutationCauses
    }

    /// A key-down in the page, then a send: the echo of the send is the person's.
    @Test func aPageMutationAfterAKeyDownEchoesAsPerson() async throws {
        let rig = try Rig()
        defer { rig.stop() }
        let page = rig.page()
        page.router.userGestureEvent = { 100 }
        try await Self.call(page, "cmux.workspace.open_url", opid: "op-gesture", params: ["url": "https://example.com"])
        let ledger = try Self.ledger(rig)
        #expect(ledger.cause(of: "op-gesture") == .person)
        // The daemon calls a page's request automation; the app knows the person's event backed it.
        #expect(Self.echo("op-gesture").cause(wire: "automation", recorded: ledger) == .person)
    }

    /// The same send with no real event in the page within 1 s: the echo is automation.
    @Test func aPageMutationWithoutAGestureEchoesAsAutomation() async throws {
        let rig = try Rig()
        defer { rig.stop() }
        let page = rig.page()
        page.router.userGestureEvent = { nil }
        try await Self.call(page, "cmux.workspace.open_url", opid: "op-script", params: ["url": "https://example.com"])
        let ledger = try Self.ledger(rig)
        #expect(ledger.cause(of: "op-script") == nil)
        #expect(Self.echo("op-script").cause(wire: "automation", recorded: ledger) == .automation)
    }

    /// The page's own `idempotency_key` is the key the daemon echoes, so it is the one recorded.
    @Test func thePagesOwnIdempotencyKeyIsRecorded() async throws {
        let rig = try Rig()
        defer { rig.stop() }
        let page = rig.page()
        page.router.userGestureEvent = { 100 }
        try await Self.call(page, "cmux.workspace.open_url", opid: "op-1",
                            params: ["url": "https://example.com", "idempotency_key": "key-1"])
        let ledger = try Self.ledger(rig)
        #expect(ledger.cause(of: "key-1") == .person)
        #expect(ledger.cause(of: "op-1") == nil)
    }
}
