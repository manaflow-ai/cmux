import Foundation
import Testing
@testable import CmuxNextDaemon

/// A keyed browser-tab create whose link to its daemon is down (#35878): it waits for the connection's reconnect (the
/// connected event) and sends once when the link is up again; its wait ends at the request deadline or at its late-reply
/// budget, whichever comes first; a cancelled create stops waiting and never sends. Before, it asked again at once on
/// every failure, a loop that never left the connection actor for its whole budget: the reconnect could not run
/// meanwhile, so the link stayed down and the create failed at the budget. Review of #35885: a create in flight when the
/// link drops sees the connection still ready (the transport's close hop has not run yet) and spun the same way on the
/// closed transport.
///
/// Socket boundary: a scripted daemon on the real JSON-lines transport (`frontend-browser-tab-keys-v1`, one tab per key,
/// as cmux-tui). Its first run answers, then exits on `test-exit` (the link drops), or in `drop` exits on the create with
/// no reply (the daemon dies with the create in flight). The connection's reconnect starts the next run, which answers
/// the handshake 1.5 s later (`back`, `drop`: the link comes back) or exits at once (`gone`: it never does).
struct FrontendBrowserTabLinkDownTests {
    private struct Recorded: DaemonRequest {
        typealias Response = JSONValue
        static let command = "test-browser-creates"
    }

    private struct Exit: DaemonRequest {
        typealias Response = JSONValue
        static let command = "test-exit"
    }

    private typealias Outcome = Result<NewFrontendBrowserTabRequest.Response, any Error>

    private static let script = #"""
    import json, os, sys, time
    mode, marker = sys.argv[1], sys.argv[2]
    relaunch = os.path.exists(marker)
    open(marker, 'a').close()
    print('{"ok":true}', file=sys.stderr, flush=True)
    if relaunch:
        if mode == 'gone':
            sys.exit(0)
        time.sleep(1.5)
    creates, tabs = [], {}
    def reply(frame, data):
        print(json.dumps({'id': frame.get('id'), 'ok': True, 'data': data}), flush=True)
    for line in sys.stdin:
        frame = json.loads(line)
        command = frame.get('cmd')
        if command == 'identify':
            caps = ['frontend-browser-tabs-v1', 'frontend-browser-tab-keys-v1']
            reply(frame, {'app': 'cmux-tui', 'protocol': 12, 'generation': 'link-down-test', 'capabilities': caps})
        elif command == 'new-frontend-browser-tab':
            if mode == 'drop' and not relaunch:
                sys.exit(0)
            creates.append(frame)
            key = frame.get('idempotency_key')
            replayed = key in tabs
            if not replayed:
                tabs[key] = 40 + len(tabs)
            reply(frame, {'surface': tabs[key], 'tab_resource_id': 'tab_%032x' % tabs[key], 'replayed': replayed})
        elif command == 'test-browser-creates':
            reply(frame, {'creates': creates, 'tabs': len(tabs)})
        elif command == 'test-exit':
            reply(frame, {})
            sys.exit(0)
        else:
            reply(frame, {})
    """#

    /// A started connection to the scripted daemon in `mode` (request deadline `deadline`), the connection's request
    /// probe, and the marker that tells the daemon's next run it is a relaunch.
    private struct Link {
        let connection: DaemonConnection
        let probe = DaemonRequestLatency()
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-link-down-\(UUID().uuidString)").path

        init(_ mode: String, deadline: Duration?) {
            var configuration = DaemonConnection.Configuration(requiredCapabilities: [], requestTimeout: deadline, terminalEnvironment: nil)
            configuration.requestLatency = probe
            let bridge = DaemonBridge.fakePython(["-c", FrontendBrowserTabLinkDownTests.script, mode, marker])
            connection = DaemonConnection(endpoint: .init(socketPath: "/tmp/cmux-link-down-test-\(UUID().uuidString).sock", bridge: bridge),
                                          configuration: configuration)
        }

        /// Drops the link (the daemon's first run exits) and returns once the connection knows it.
        func drop() async throws {
            _ = try await connection.request(Exit())
            var waited = 0
            while await connection.isReady, waited < 300 {
                try await Task.sleep(for: .milliseconds(10))
                waited += 1
            }
            let dropped = await !connection.isReady
            try #require(dropped, "the link never dropped")
        }

        /// Whether the link is up again within 5 s.
        func reconnected() async throws -> Bool {
            var waited = 0
            while await !connection.isReady, waited < 500 {
                try await Task.sleep(for: .milliseconds(10))
                waited += 1
            }
            return await connection.isReady
        }

        /// The creates the daemon's current run received; nil when it does not answer.
        func creates() async -> Int? {
            let recorded = try? await connection.request(Recorded())
            return recorded?["creates"]?.arrayValue?.count
        }

        func create() async throws -> NewFrontendBrowserTabRequest.Response {
            try await connection.newFrontendBrowserTab(url: "http://127.0.0.1/link-down", engine: .webkit, in: nil)
        }
    }

    /// Runs `body` on a started link to the scripted daemon in `mode`, then closes the connection (and the daemon's run)
    /// and removes the marker, whatever `body` did.
    private static func withLink<T>(_ mode: String, deadline: Duration?, _ body: (Link) async throws -> T) async throws -> T {
        let link = Link(mode, deadline: deadline)
        let result: Result<T, any Error>
        do {
            try await link.connection.start()
            result = .success(try await body(link))
        } catch {
            result = .failure(error)
        }
        await link.connection.closeAndWait()
        try? FileManager.default.removeItem(atPath: link.marker)
        return try result.get()
    }

    /// The outcome of one create on `link`, and how long it took.
    private static func timedCreate(on link: Link) async -> (Outcome, Duration) {
        let started = ContinuousClock.now
        let outcome: Outcome
        do {
            outcome = .success(try await link.create())
        } catch {
            outcome = .failure(error)
        }
        return (outcome, ContinuousClock.now - started)
    }

    /// The link comes back 1.5 s after the drop: the create goes out once it is up, and the daemon makes the one tab.
    @Test func aCreateSentWhileTheLinkIsDownGoesOnceWhenTheLinkIsBack() async throws {
        let (outcome, took, creates) = try await Self.withLink("back", deadline: .seconds(10)) { link in
            try await link.drop()
            let (outcome, took) = await Self.timedCreate(on: link)
            return (outcome, took, await link.creates())
        }
        let created = try outcome.get()
        #expect(creates == 1, "the create reached the daemon \(String(describing: creates)) times, not once")
        #expect(created.surface == SurfaceID(rawValue: 40))
        #expect(took < .seconds(6), "the create waited \(took) for a link that came back 1.5 s after the drop")
    }

    /// The daemon dies with the create in flight (no reply) and is back 1.5 s later: the create sees the connection still
    /// ready on its closed transport, waits for the reconnect and goes out once on the new link. It never sends again in a
    /// loop on the closed transport (the connection's request probe counts each send the transport failed).
    @Test func aCreateInFlightWhenTheLinkDropsGoesOnceWhenTheLinkIsBack() async throws {
        let (outcome, took, creates, failedSends) = try await Self.withLink("drop", deadline: .seconds(10)) { link in
            let (outcome, took) = await Self.timedCreate(on: link)
            return (outcome, took, await link.creates(), link.probe.snapshot().errors)
        }
        #expect(failedSends <= 2, "the create was sent \(failedSends) times on a closed transport, not once")
        let created = try outcome.get()
        #expect(creates == 1, "the create reached the daemon's next run \(String(describing: creates)) times, not once")
        #expect(created.surface == SurfaceID(rawValue: 40))
        #expect(took < .seconds(6), "the create waited \(took) for a link that came back 1.5 s after the drop")
    }

    /// A create cancelled while it waits for the link ends at once, and never goes out when the link is back.
    @Test func aCreateCancelledWhileTheLinkIsDownEndsAndNeverSends() async throws {
        let (outcome, ended, back, creates) = try await Self.withLink("back", deadline: .seconds(10)) { link in
            try await link.drop()
            let create = Task { try await link.create() }
            try await Task.sleep(for: .milliseconds(300))
            let cancelled = ContinuousClock.now
            create.cancel()
            let outcome = await create.result
            let ended = ContinuousClock.now - cancelled
            let back = try await link.reconnected()
            var creates: Int?
            if back { creates = await link.creates() }
            return (outcome, ended, back, creates)
        }
        if case .success = outcome { Issue.record("the cancelled create went on and made its tab") }
        #expect(ended < .milliseconds(600), "the cancelled create ended \(ended) after its cancel")
        #expect(back, "the link did not come back")
        #expect(creates == 0, "the cancelled create reached the daemon \(String(describing: creates)) times after the link came back")
    }

    /// The link never comes back, and the request deadline (2 s) is shorter than the late-reply budget (10 s): the
    /// create fails at the request deadline.
    @Test func aCreateWhoseLinkStaysDownFailsAtTheRequestDeadline() async throws {
        let (outcome, took) = try await Self.withLink("gone", deadline: .seconds(2)) { link in
            try await link.drop()
            return await Self.timedCreate(on: link)
        }
        if case .success = outcome { Issue.record("a create whose link never came back succeeded") }
        #expect(took < .seconds(4), "the create failed \(took) after its start; the request deadline is 2 s")
    }

    /// The link never comes back, at the app's request deadline (30 s), longer than the late-reply budget: the create
    /// fails at the budget, so `action.run`'s limit for it (the budget plus one request deadline, `ActionRunLimit`) still
    /// covers its last send (review of #35885).
    @Test func aCreateWhoseLinkStaysDownFailsAtItsLateReplyBudget() async throws {
        let (outcome, took) = try await Self.withLink("gone", deadline: DaemonConnection.defaultRequestTimeout) { link in
            try await link.drop()
            return await Self.timedCreate(on: link)
        }
        if case .success = outcome { Issue.record("a create whose link never came back succeeded") }
        let bound = NewFrontendBrowserTabRequest.lateReplyBudget + .seconds(3)
        #expect(took < bound, "the create failed \(took) after its start; its late-reply budget is \(NewFrontendBrowserTabRequest.lateReplyBudget)")
    }
}
