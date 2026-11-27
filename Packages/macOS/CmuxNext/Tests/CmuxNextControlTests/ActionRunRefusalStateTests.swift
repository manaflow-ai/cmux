import CmuxNextActions
@testable import CmuxNextControl
import CmuxNextSettings
import Foundation
import Testing

/// `action.run` says who refused in `data.state`. `rejected`: the app decided (the agent chat
/// cannot split, `SplitRoomCheck`), and no second try changes that. `not_run`: the app did not
/// get to the request (a reconnecting daemon, a full queue), and a second try may pass. The CLI
/// and the MCP tools ask a `not_run` request again until its deadline, 45 s for a run, so a
/// refusal the app decided must not look like one: `cmux action run splitDown` on the agent chat
/// waited 45 s to say "The agent chat can't be split.".
@MainActor
@Suite(.timeLimit(.minutes(1))) struct ActionRunRefusalStateTests {
    /// The text `SplitRoomCheck` refuses a script's split of the agent chat with
    /// (`RefusalStrings.chatDockCannotSplit`).
    static let chatDock = "The agent chat can't be split."

    /// `action.run splitDown` through the real registry and bridge, as the CLI sends it (keyed, behind the
    /// read barrier); its handler refuses the way the split room check does.
    private func refusedSplit(barrier: (@Sendable () async throws -> UInt64)? = nil) async -> ControlError? {
        let registry = ActionRegistry.standard()
        let bridge = RegistryControlBridge(registry: registry)
        let router = ControlRouter(identity: testIdentity(), executor: bridge, configuration: .loadTolerant)
        registry.bindEffect("splitDown", effect: { _ in .refused(Self.chatDock) })
        bridge.attach(to: router)
        defer { bridge.detach() }
        var params: [String: JSONValue] = ["action": "splitDown", "idempotency_key": "k-split", "origin": "script"]
        if let barrier {
            router.registerSyncBarrier(barrier)
            params["after"] = "sync"
        }
        return await router.handle(ControlRequest(id: "1", method: "action.run", params: params)).failure
    }

    @Test func aSplitTheAppRefusesIsRejectedOnTheWire() async throws {
        let error = try #require(await refusedSplit())
        #expect(error.code == "unavailable")
        #expect(error.data?["reason"]?.stringValue == Self.chatDock)
        // Nothing applied (no "may still apply" note), and the app decided: not a request to send again.
        #expect(error.data?["not_run"]?.boolValue == true)
        #expect(error.data?["state"]?.stringValue == "rejected")
        let line = ControlWire.encode(id: "1", error: error)
        #expect(line.contains(#""state":"rejected""#), "\(line)")
        #expect(!line.contains(#""state":"not_run""#), "\(line)")
    }

    /// Every outcome the app decides before a handler's work starts, not only a handler's refusal.
    @Test(arguments: [
        ControlActionOutcome.refused("not enough room to split this pane"), .unavailable, .disabled, .notBound,
        .notFound("no such pane"), .confirmationRequired,
    ])
    func anOutcomeTheAppDecidedIsRejected(_ outcome: ControlActionOutcome) async throws {
        let router = ControlRouter(identity: testIdentity(), executor: RefusingExecutor(outcome), configuration: .loadTolerant)
        router.snapshots.publish { $0 = BrowserOpenSplitTests.snapshot() }
        let reply = await router.handle(ControlRequest(id: "1", method: "action.run", params: [
            "action": "openBrowser", "idempotency_key": "k-1",
        ]))
        let error = try #require(reply.failure)
        #expect(error.data?["not_run"]?.boolValue == true, "\(error)")
        #expect(error.data?["state"]?.stringValue == "rejected", "\(error)")
    }

    /// The read barrier on a daemon connection that is not back yet: the app did not get to the request, so
    /// the handler never ran and the caller asks again (#32724).
    @Test func aRequestTheAppDidNotGetToStaysNotRun() async throws {
        struct Lost: Error {}
        let error = try #require(await refusedSplit(barrier: { throw Lost() }))
        #expect(error.code == "unavailable")
        #expect(error.data?["not_run"]?.boolValue == true)
        #expect(error.data?["state"]?.stringValue == "not_run")
        #expect(error.data?["reason"] == nil)
    }

    /// A refusal from the action's work may have applied part of the change: it says neither.
    @Test func aRefusalFromTheWorkSaysNeither() async throws {
        let failure = ActionWorkFailure(refusal: .unavailable, reason: "the group was made but its replies were not set")
        let router = ControlRouter(identity: testIdentity(), executor: RefusingExecutor(.ran, failure: failure), configuration: .loadTolerant)
        router.snapshots.publish { $0 = BrowserOpenSplitTests.snapshot() }
        let reply = await router.handle(ControlRequest(id: "1", method: "action.run", params: [
            "action": "openBrowser", "idempotency_key": "k-1",
        ]))
        let error = try #require(reply.failure)
        #expect(error.code == "unavailable")
        #expect(error.data?["not_run"] == nil)
        #expect(error.data?["state"] == nil)
    }
}
