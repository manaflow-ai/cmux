import Foundation
import Testing
@testable import CmuxNextCloud

@Suite("Cloud Codex broker target")
struct CloudCodexBrokerTargetTests {
    @Test func readsPrettyPrintedRunningDaemonCapabilities() {
        let output = "{\n  \"capabilities\": [\n    \"codex-external-access-v1\"\n  ]\n}"
        #expect(CloudCodexBrokerTarget.supportsExternalAccess(output))
        #expect(!CloudCodexBrokerTarget.supportsExternalAccess("{\"capabilities\":[]}"))
    }

    /// A machine the caller does not own is refused before anything runs on it.
    @Test func aMachineTheCallerDoesNotOwnIsRefusedBeforeGuestExecution() async throws {
        let capability = try await target(kind: "team", owns: { false }).capability()
        #expect(capability == .init(ownerVM: false, protocolVersion: 0, codexExternalAccessToken: false))
    }

    @Test func authoritativeOwnerStillRequiresRunningBridgeCapability() async throws {
        let ready = try await target(kind: "owner", owns: { true }).capability()
        #expect(ready == .init(ownerVM: true, protocolVersion: 1, codexExternalAccessToken: true))
        let unsupported = try await target(kind: "unsupported", owns: { true }).capability()
        #expect(unsupported == .init(ownerVM: true, protocolVersion: 0, codexExternalAccessToken: false))
    }

    /// An owner answer that fails fails the capability: it never falls back to guest files.
    @Test func ownershipFailuresNeverFallBackToGuestFiles() async {
        struct Refused: Error {}
        await #expect(throws: (any Error).self) {
            _ = try await target(kind: "failed", owns: { throw Refused() }).capability()
        }
    }

    private func target(kind: String, owns: @escaping @Sendable () async throws -> Bool) -> CloudCodexBrokerTarget {
        let configuration = CloudConfiguration.resolve(bundleID: nil,
            bundled: ["CMUX_VM_API_BASE_URL": "https://\(kind).invalid"], process: [:], isDebugBuild: true)
        let transport = URLSessionConfiguration.ephemeral
        transport.protocolClasses = [ExecAPI.self]
        let api = CloudAPIClient(configuration: configuration, tokens: { ("access", "refresh") },
            teamID: { "different-team" }, session: URLSession(configuration: transport))
        return CloudCodexBrokerTarget(api: api, machineID: "vm-1", scope: .init(userID: "user-1", teamID: "pinned-team"),
                                      callerOwnsVM: owns, isLive: { true })
    }

    /// Each request carries its fixture in its URL; parallel cases share no mutable state.
    nonisolated final class ExecAPI: URLProtocol {
        override class func canInit(with _: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func stopLoading() {}

        override func startLoading() {
            guard let url = request.url else { return }
            #expect(request.value(forHTTPHeaderField: "X-Cmux-Team-Id") == "pinned-team")
            let kind = url.host?.components(separatedBy: ".").first ?? "missing"
            var status = 200
            let body: String
            switch url.path {
            case "/api/vm/vm-1/exec":
                #expect(kind == "owner" || kind == "unsupported", "Non-owner must be rejected before guest execution")
                body = kind == "unsupported" ? #"{"exitCode":0,"stdout":"{\"capabilities\":[]}"}"#
                    : #"{"exitCode":0,"stdout":"{\"capabilities\":[\"codex-external-access-v1\"]}"}"#
            default:
                Issue.record("Unexpected broker request: \(url.path)")
                status = 500
                body = "{}"
            }
            guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]) else { return }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
}
