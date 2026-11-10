@testable import CmuxNextCloud
import CmuxNextCompat
import Foundation
import Observation
import Testing

/// The app's half of a Cloud API call (``CloudDaemon``): the params it sends the daemon's `cloud.*`
/// operation and how it reads the SDK's envelope back. The requests themselves are cmux-cloud-api's.
struct CloudDaemonTests {
    static let api = URL(string: "https://api.invalid") ?? URL(fileURLWithPath: "/")
    var api: URL { Self.api }

    @Test func aCallSendsTheRouteAndArgsAsTheOperationsParams() async throws {
        let fake = CloudDaemonFake { _, _ in CloudDaemonFake.read(#"{"domains":1}"#) }
        let route = CloudDaemon.Route(api: api, auth: .stack, credential: "access", refresh: "refresh", team: "team-1",
                                      appVersion: "cmux-next", localOnly: true)
        let body = try await fake.daemon.call("vm.domains", ["x": 1], as: route, wait: .seconds(1))
        #expect(String(decoding: body, as: UTF8.self) == #"{"domains":1}"#)
        let sent = try #require(fake.sent.first)
        #expect(sent.operation == "cloud.vm.domains" && !sent.mutation)
        #expect(sent.params["machine"] as? String == "current" && sent.params["session"] as? String == "current")
        #expect(sent.params["auth"] as? String == "stack" && sent.params["access_token"] as? String == "access")
        #expect(sent.params["refresh_token"] as? String == "refresh" && sent.params["team"] as? String == "team-1")
        #expect(sent.params["local_only"] as? Bool == true && sent.args["x"] as? Int == 1)
        #expect(sent.params["key_base64"] == nil)
    }

    @Test func aMutationAnswersItsValue() async throws {
        let fake = CloudDaemonFake { _, _ in CloudDaemonFake.value(#"{"id":"run_1"}"#) }
        let body = try await fake.daemon.call("runs.create", as: .init(api: api, auth: .stack, credential: "a"), wait: .seconds(1))
        #expect(String(decoding: body, as: UTF8.self) == #"{"id":"run_1"}"#)
        #expect(fake.sent.first?.mutation == true)
    }

    @Test(arguments: [
        (#"{"kind":"timed_out","path":"/api/runs"}"#, CloudAPIError.timedOut("/api/runs")),
        (#"{"kind":"transport","message":"offline"}"#, .transport("offline")),
        (#"{"kind":"no_backend"}"#, .noBackend(CloudDaemonTests.api)),
        (#"{"kind":"http","status":409,"code":"vm_busy","message":"Busy.","action":"Retry.","trace_id":"t1"}"#,
         .http(status: 409, code: "vm_busy", message: "Busy.", action: "Retry.", traceId: "t1")),
        (#"{"kind":"plan_required","message":"Upgrade.","upgrade_url":"https://cmux.com/pricing","plan":"max"}"#,
         .planRequired(message: "Upgrade.", upgradeURL: URL(string: "https://cmux.com/pricing"), plan: "max")),
        (#"{"kind":"decoding","message":"no id"}"#, .decoding("no id")),
    ])
    func aRefusalIsTheLibrarysFailure(failure: String, expected: CloudAPIError) async {
        let fake = CloudDaemonFake { _, _ in CloudDaemonFake.failed(failure) }
        await #expect(throws: expected) {
            _ = try await fake.daemon.call("vm.domains", as: .init(api: api, auth: .worker, credential: "a"), wait: .seconds(1))
        }
    }

    @Test func aRefusalTheDaemonMadeItselfIsATransportFailure() async {
        let refused = CloudDaemonFake { _, _ in #"{"ok":false,"error":{"code":"operation.failed","message":"no","details":{"reason":"x"}}}"# }
        await #expect(throws: CloudAPIError.transport("no")) {
            _ = try await refused.daemon.call("vm.domains", as: .init(api: api, auth: .worker, credential: "a"), wait: .seconds(1))
        }
        // Busy (its call slots or its long polls' are taken) reads as such, for a caller to back off.
        let fake = CloudDaemonFake { _, _ in #"{"ok":false,"error":{"code":"operation.failed","message":"busy","details":{"reason":"busy"}}}"# }
        await #expect(throws: CloudDaemon.busy) {
            _ = try await fake.daemon.call("vm.domains", as: .init(api: api, auth: .worker, credential: "a"), wait: .seconds(1))
        }
    }

    @Test func noDaemonSendsNothing() async {
        await #expect(throws: CloudAPIError.self) {
            _ = try await CloudDaemon.none.call("vm.domains", as: .init(api: api, auth: .worker, credential: "a"), wait: .seconds(1))
        }
    }

    /// A daemon that is still starting (or handing off to an upgraded one) when a call is made:
    /// the call waits for its socket instead of failing, and answers once it comes.
    @Test func aCallMadeBeforeTheDaemonIsUpWaitsForIt() async throws {
        let late = await LateDaemon()
        let found = Task {
            try await CloudDaemon.socket({ await late.socket }, changes: { ObservationStream { @MainActor in late.socket } },
                                         within: .seconds(30))
        }
        for _ in 0..<5 { await Task.yield() }
        await MainActor.run { late.socket = "/tmp/cmux-late.sock" }
        #expect(try await found.value == "/tmp/cmux-late.sock")
    }

    /// No daemon within the bound: the call fails as before.
    @Test func noDaemonWithinTheBoundIsNotRunning() async {
        let late = await LateDaemon()
        await #expect(throws: CloudAPIError.transport("the cmux daemon is not running")) {
            _ = try await CloudDaemon.socket({ await late.socket }, changes: { ObservationStream { @MainActor in late.socket } },
                                             within: .milliseconds(50))
        }
    }

    /// A call made while the daemon's call slots are all taken (its answer `busy`) is asked again
    /// after a backoff, never dropped (the hand-off list at sign-in). Any other failure ends it.
    @Test func aBusyDaemonIsAskedAgainAndAnyOtherFailureEndsIt() async throws {
        let calls = BusyOnce()
        #expect(try await CloudDaemon.retryingBusy { try await calls.call() } == "listed")
        #expect(await calls.count == 2)
        await #expect(throws: CloudAPIError.http(status: 404, code: nil, message: nil)) {
            _ = try await CloudDaemon.retryingBusy { () async throws -> String in throw CloudAPIError.http(status: 404, code: nil, message: nil) }
        }
    }
}

/// A call that answers busy once, then `"listed"`.
private actor BusyOnce {
    private(set) var count = 0
    func call() throws -> String {
        count += 1
        if count == 1 { throw CloudDaemon.busy }
        return "listed"
    }
}

/// A local daemon whose connection (its socket) comes later.
@MainActor @Observable private final class LateDaemon {
    var socket: String?
}
