@testable import CmuxNextCloud
import Foundation
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

    @Test func aKeyGoesBase64InTheParams() async throws {
        let fake = CloudDaemonFake()
        let key = CloudSecretBytes(Array("person-key\n".utf8))
        _ = try await fake.daemon.call("owner.acpmux_keyed_start", ["key_length": 11], as: .init(api: api, auth: .owner, credential: "a"),
                                       key: key, wait: .seconds(1))
        #expect(fake.sent.first?.params["key_base64"] as? String == Data("person-key\n".utf8).base64EncodedString())
        for length in 0..<5 {
            let bytes = Array("abcd".utf8.prefix(length))
            let params = CloudSecretBytes(Array("{}".utf8))
            params.appendField("k", base64Of: CloudSecretBytes(bytes))
            let object = try #require(try JSONSerialization.jsonObject(with: Data(params.text.utf8)) as? [String: String])
            #expect(object["k"] == Data(bytes).base64EncodedString())
        }
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
        let fake = CloudDaemonFake { _, _ in #"{"ok":false,"error":{"code":"operation.failed","message":"busy","details":{"reason":"busy"}}}"# }
        await #expect(throws: CloudAPIError.transport("busy")) {
            _ = try await fake.daemon.call("vm.domains", as: .init(api: api, auth: .worker, credential: "a"), wait: .seconds(1))
        }
    }

    @Test func noDaemonSendsNothing() async {
        await #expect(throws: CloudAPIError.self) {
            _ = try await CloudDaemon.none.call("vm.domains", as: .init(api: api, auth: .worker, credential: "a"), wait: .seconds(1))
        }
    }
}
