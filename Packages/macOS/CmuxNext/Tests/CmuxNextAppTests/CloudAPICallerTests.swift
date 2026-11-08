@testable import CmuxNextCloud
import CmuxNextDaemon
import Foundation
import Testing

/// The app's Cloud API calls are the local daemon's `cloud.*` operations: the fields each call
/// sends, a mutation's answer read from under `value`, and each refusal read back as the
/// ``CloudAPIError`` the crate's failure names (cmux-cloud-api `Failure::json`).
@Suite struct CloudAPICallerTests {
    private static func refused(with failure: String) async -> (any Error)? {
        let fake = FakeCloudAPI { _ in throw FakeCloudAPI.refusal(failure) }
        do {
            _ = try await fake.classic().listNetworks()
            return nil
        } catch {
            return error
        }
    }

    @Test func aReadSendsTheClassicCredentialsAndAnswersTheBody() async throws {
        let fake = FakeCloudAPI { _ in FakeCloudAPI.json(#"[{"id":"net-1","scope":"team"}]"#) }
        let networks = try await fake.classic().listNetworks()
        #expect(networks.count == 1)
        let call = try #require(fake.seen.first)
        #expect(call.operation == "cloud.vm.networks")
        #expect(call.fields["auth"] == .string("stack"))
        #expect(call.fields["access_token"] == .string("access"))
        #expect(call.fields["refresh_token"] == .string("refresh"))
        #expect(call.fields["team"] == .string("team-1"))
        #expect(call.fields["app_version"] == .string("cmux-next"))
        #expect(call.fields["local_only"] == nil)
    }

    @Test func aSignInThatFailsSendsNothing() async {
        let fake = FakeCloudAPI()
        let configuration = CloudConfiguration.resolve(bundleID: nil, bundled: ["CMUX_VM_API_BASE_URL": "https://vm-api.standin.invalid"],
                                                       process: [:], isDebugBuild: true)
        struct SignedOut: Error {}
        let api = CloudAPIClient(configuration: configuration, tokens: { throw SignedOut() }, teamID: { nil }, caller: fake.caller)
        await #expect(throws: CloudAPIError.notSignedIn) { _ = try await api.listDomains() }
        #expect(fake.seen.isEmpty)
    }

    @Test func aFreeAccountsRefusalIsThePlanRefusal() async {
        let error = await Self.refused(with: #"{"kind":"plan_required","message":"Cloud VMs require a cmux Pro subscription.","upgrade_url":"https://cmux.com/pricing","plan":"pro"}"#)
        #expect(error as? CloudAPIError == .planRequired(message: "Cloud VMs require a cmux Pro subscription.",
                                                          upgradeURL: URL(string: "https://cmux.com/pricing")))
    }

    @Test func aMaxPlanRefusalNamesMax() async {
        let error = await Self.refused(with: #"{"kind":"plan_required","message":"Used up.","upgrade_url":null,"plan":"max"}"#)
        #expect(error as? CloudAPIError == .planRequired(message: "Used up.", upgradeURL: nil, plan: "max"))
    }

    @Test func anHTTPRefusalKeepsItsCodeActionAndTrace() async {
        let error = await Self.refused(with: #"{"kind":"http","status":402,"code":"vm_create_credits_insufficient","message":"Out of credits.","action":"Run `cmux billing`","trace_id":"t-1"}"#)
        #expect(error as? CloudAPIError == .http(status: 402, code: "vm_create_credits_insufficient", message: "Out of credits.",
                                                  action: "Run `cmux billing`", traceId: "t-1"))
    }

    @Test func eachOtherFailureKeepsItsKind() async {
        #expect(await Self.refused(with: #"{"kind":"timed_out","path":"/api/vm/network"}"#) as? CloudAPIError == .timedOut("/api/vm/network"))
        #expect(await Self.refused(with: #"{"kind":"transport","message":"offline"}"#) as? CloudAPIError == .transport("offline"))
        #expect(await Self.refused(with: #"{"kind":"decoding","message":"not JSON"}"#) as? CloudAPIError == .decoding("not JSON"))
        #expect(await Self.refused(with: #"{"kind":"no_backend"}"#) as? CloudAPIError
            == .noBackend(URL(string: "https://vm-api.standin.invalid") ?? URL(fileURLWithPath: "/")))
    }

    @Test func aDaemonThatIsGoneOrRefusesTheFieldsIsATransportFailure() async {
        let gone = FakeCloudAPI { _ in throw DaemonError.notConnected }
        await #expect(throws: CloudAPIError.transport(DaemonError.notConnected.description)) { _ = try await gone.classic().listDomains() }
        let invalid = FakeCloudAPI { _ in
            throw DaemonError.command(cmd: "cloud.vm.domains", message: "api is the API's base URL", code: "validation.invalid")
        }
        await #expect(throws: CloudAPIError.transport("api is the API's base URL")) { _ = try await invalid.classic().listDomains() }
    }
}
