import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import Foundation
import Testing

/// Reopen Closed Tab, Reopen Closed Screen, and the history lists (Recently
/// Closed…, `history.list`) read the daemon's closed history and reopen
/// through `closed.reopen` when the daemon serves it; the app's own trackers
/// record nothing for that daemon.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct DaemonClosedHistoryTests {
    nonisolated static let state = #"""
    {"closed":[
      {"id":"closed_tab","kind":"tab","name":"logs","workspace_id":"ws_w","pane_id":"pane_p","index":1,"closed_at_ms":"30","screens":[{"name":null,"tabs":[{"kind":"terminal","name":"logs","cwd":"/tmp","url":null,"browser_profile_id":null,"pinned":false}]}]},
      {"id":"closed_screen","kind":"screen","name":"build","workspace_id":"ws_w","pane_id":null,"index":0,"closed_at_ms":"20","screens":[]},
      {"id":"closed_ws","kind":"workspace","name":"old","workspace_id":null,"pane_id":null,"index":0,"closed_at_ms":"10","screens":[]}
    ]}
    """#.replacingOccurrences(of: "\n", with: "")

    nonisolated static func reopenReply(_ operation: String, _ params: [String: JSONValue]) -> String {
        guard operation == "closed.reopen" else { return "{}" }
        return #"{"closed_id":"\#(params["closed"]?.stringValue ?? "")","kind":"tab","workspace_id":"ws_w","screen_ids":[],"tab_ids":["tab_a"]}"#
    }

    /// Waits up to 10 s; a timeout records an Issue at the caller (``waitForCondition``).
    func waitUntil(_ what: String? = nil, sourceLocation: SourceLocation = #_sourceLocation,
                   _ condition: () -> Bool) async throws {
        try await waitForCondition(what, timeout: .seconds(10), sourceLocation: sourceLocation, condition)
    }

    /// Bound services whose local daemon serves `daemon`.
    func services(_ daemon: StateDaemon) async throws -> AppServices {
        let services = ActionBindingCoverageTests.boundServices()
        services.daemon.start(makeConnection: { daemon.connection() })
        try await waitUntil { services.daemon.store.isLoaded && services.daemon.store.servesStateResources && services.daemon.store.session.known }
        return services
    }

    func run(_ services: AppServices, _ id: ActionID, _ invocation: ActionInvocation = ActionInvocation()) async {
        let work = services.registry.capturingWork { _ = services.registry.perform(id, invocation: invocation) }
        for task in work { #expect(await task.value == nil) }
    }

    func shutdown(_ services: AppServices) {
        for controller in services.windows.controllers { controller.window?.close() }
        services.daemon.shutdownConnection()
    }

    @Test func reopenClosedTabReopensTheNewestClosedTabOnTheDaemon() async throws {
        let daemon = try StateDaemon(state: Self.state, reply: Self.reopenReply)
        defer { daemon.stop() }
        let services = try await services(daemon)
        defer { shutdown(services) }
        #expect(services.daemon.store.closedItems.map(\.id) == ["closed_tab", "closed_screen", "closed_ws"])

        await run(services, "reopenClosedBrowserPanel")
        #expect(daemon.operations.last == "closed.reopen")
        #expect(daemon.params(of: "closed.reopen")?["closed"] == .string("closed_tab"))
        #expect(daemon.requests.last?["idempotency_key"]?.stringValue?.isEmpty == false)

        await run(services, "screen.reopenClosed")
        #expect(daemon.params(of: "closed.reopen")?["closed"] == .string("closed_screen"))
    }

    @Test func theHistoryListsTheDaemonsClosedItemsAndReopensThem() async throws {
        let daemon = try StateDaemon(state: Self.state, reply: Self.reopenReply)
        defer { daemon.stop() }
        let services = try await services(daemon)
        defer { shutdown(services) }
        let closed = services.history.closedEntries()
        #expect(Set(closed.map(\.title)) == ["logs", "build", "old"])
        let workspace = try #require(closed.first { $0.title == "old" })
        HistoryRestorer(services: services).open(workspace)
        try await waitUntil { daemon.params(of: "closed.reopen")?["closed"] == .string("closed_ws") }
        #expect(daemon.params(of: "closed.reopen")?["closed"] == .string("closed_ws"))
    }

    @Test func reopenClosedWorkspaceUsesTheSharedHistoryAndSkipsNewerTabsAndScreens() async throws {
        let daemon = try StateDaemon(state: Self.state, reply: Self.reopenReply)
        defer { daemon.stop() }
        let services = try await services(daemon)
        defer { shutdown(services) }

        await run(services, "reopenClosedWorkspace")
        #expect(daemon.params(of: "closed.reopen")?["closed"] == .string("closed_ws"))
        #expect(daemon.requests.last?["idempotency_key"]?.stringValue?.isEmpty == false)
    }

    @Test func reopenClosedWorkspaceRefusesEmptyHistoryVisibly() async throws {
        let daemon = try StateDaemon(state: "{}")
        defer { daemon.stop() }
        let services = try await services(daemon)
        defer { shutdown(services) }
        var refusals: [String] = []
        services.registry.refusalObserver = { message, _ in refusals.append(message) }

        _ = services.registry.perform("reopenClosedWorkspace")
        #expect(refusals == [RefusalStrings.noRecentlyClosedWorkspace])
        #expect(!daemon.operations.contains("closed.reopen"))
    }

    @Test func reopenClosedWorkspaceCreatesAWindowWhenTheLastWindowWasClosed() async throws {
        let daemon = try StateDaemon(state: Self.state, reply: Self.reopenReply)
        defer { daemon.stop() }
        let services = try await services(daemon)
        defer {
            for controller in services.windows.controllers { controller.window?.close() }
            services.daemon.shutdownConnection()
        }
        #expect(services.windows.controllers.isEmpty)
        let workspace = try #require(services.daemon.store.workspace(resourceID: ResourceID(rawValue: "ws_w")))

        await run(services, "reopenClosedWorkspace")
        #expect(services.windows.controllers.count == 1)
        #expect(services.windows.registry.value.owner(of: workspace.id) != nil)
    }

    @Test func aWorkspaceReopenedByAnotherClientProducesALocalizedRefusal() async throws {
        let daemon = try StateDaemon(state: Self.state, failure: { operation in
            operation == "closed.reopen" ? #"{"code":"resource.not_found","message":"gone","retryable":false}"# : nil
        })
        defer { daemon.stop() }
        let services = try await services(daemon)
        defer { shutdown(services) }
        var refusals: [String] = []
        services.registry.refusalObserver = { message, _ in refusals.append(message) }

        let work = services.registry.capturingWork { _ = services.registry.perform("reopenClosedWorkspace") }
        #expect(work.count == 1)
        for task in work {
            let failure = await task.value
            #expect(failure?.refusal == .unavailable)
            #expect(failure?.message == RefusalStrings.noRecentlyClosedWorkspace)
        }
        #expect(refusals == [RefusalStrings.noRecentlyClosedWorkspace])
    }

    @Test func aMissingReopenedWorkspaceDoesNotSelectAnUnrelatedWorkspaceOrReportSuccess() async throws {
        let daemon = try StateDaemon(state: Self.state, reply: { _, _ in
            #"{"closed_id":"closed_ws","kind":"workspace","workspace_id":"ws_missing","screen_ids":[],"tab_ids":[]}"#
        })
        defer { daemon.stop() }
        let services = try await services(daemon)
        defer { shutdown(services) }
        #expect(services.daemon.store.workspace(resourceID: ResourceID(rawValue: "ws_w")) != nil)

        let work = services.registry.capturingWork { _ = services.registry.perform("reopenClosedWorkspace") }
        #expect(work.count == 1)
        for task in work {
            let failure = await task.value
            #expect(failure?.mayHaveApplied == true)
            #expect(failure?.message == RefusalStrings.noWorkspace("ws_missing"))
        }
    }

    @Test func aLaterMirrorEventFindsTheExactWorkspaceAfterAnUnrelatedOne() async throws {
        let store = DaemonStore()
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(ReopenClosedTabTests.identify.utf8))
        _ = store.apply(.connected(identity, generationChanged: false))
        let clock = ManualClock()
        let wait = Task { await DaemonClosedHistory.workspaceAfterReopen(ResourceID(rawValue: "ws_restored"), in: store, clock: clock) }
        await clock.sleepers()
        let tree = #"{"workspace_revision":1,"generation":"GEN","registry_id":"r","workspaces":[{"id":1,"name":"other","resource_id":"ws_other","screens":[]},{"id":2,"name":"restored","resource_id":"ws_restored","screens":[]}]}"#
        store.apply(snapshot: try JSONDecoder().decode(DaemonTree.self, from: Data(tree.utf8)))
        let restored = try #require(store.workspace(resourceID: ResourceID(rawValue: "ws_restored")))
        #expect(await wait.value == restored.id)
        #expect(restored.id != store.workspaces.first?.id)
    }

    @Test func aMissingWorkspaceWaitEndsAtItsDeadline() async {
        let store = DaemonStore()
        let clock = ManualClock()
        let wait = Task { await DaemonClosedHistory.workspaceAfterReopen(ResourceID(rawValue: "ws_missing"), in: store, clock: clock) }
        await clock.sleepers()
        clock.advance(by: .seconds(5))
        #expect(await wait.value == nil)
    }

    @Test func cancellingAWorkspaceWaitDoesNotWaitForTheDeadline() async {
        let store = DaemonStore()
        let clock = ManualClock()
        let wait = Task { await DaemonClosedHistory.workspaceAfterReopen(ResourceID(rawValue: "ws_missing"), in: store, clock: clock) }
        await clock.sleepers()
        wait.cancel()
        #expect(await wait.value == nil)
    }
}
