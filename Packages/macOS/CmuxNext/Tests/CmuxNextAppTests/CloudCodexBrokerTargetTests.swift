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

    @Test(arguments: ["team", "missing", "null", "unknown", "uppercase", "padded"])
    func rejectsAnythingExceptAuthoritativeOwner(kind: String) async throws {
        let capability = try await target(kind: kind).capability()
        #expect(capability == .init(ownerVM: false, protocolVersion: 0, codexExternalAccessToken: false))
    }

    @Test func authoritativeOwnerStillRequiresRunningBridgeCapability() async throws {
        let ready = try await target(kind: "owner").capability()
        #expect(ready == .init(ownerVM: true, protocolVersion: 1, codexExternalAccessToken: true))
        let unsupported = try await target(kind: "unsupported").capability()
        #expect(unsupported == .init(ownerVM: true, protocolVersion: 0, codexExternalAccessToken: false))
    }

    @Test(arguments: ["malformed", "failed"])
    func ownershipFailuresNeverFallBackToGuestFiles(kind: String) async {
        await #expect(throws: (any Error).self) {
            _ = try await target(kind: kind).capability()
        }
    }

    private func target(kind: String) -> CloudCodexBrokerTarget {
        let configuration = CloudConfiguration.resolve(bundleID: nil,
            bundled: ["CMUX_VM_API_BASE_URL": "https://\(kind).invalid"], process: [:], isDebugBuild: true)
        let transport = URLSessionConfiguration.ephemeral
        transport.protocolClasses = [OwnershipAPI.self]
        let api = CloudAPIClient(configuration: configuration, tokens: { ("access", "refresh") },
            teamID: { "different-team" }, session: URLSession(configuration: transport))
        return CloudCodexBrokerTarget(api: api, machineID: "vm-1", scope: .init(userID: "user-1", teamID: "pinned-team"))
    }

    /// Each request carries its fixture in its URL; parallel cases share no mutable state.
    nonisolated final class OwnershipAPI: URLProtocol {
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
            case "/api/vm/vm-1/attach-endpoint":
                #expect(request.httpMethod == "POST")
                let field: String
                switch kind {
                case "missing": field = ""
                case "null": field = #", "vmKind": null"#
                case "malformed": field = #", "vmKind": 7"#
                case "uppercase": field = #", "vmKind": "OWNER""#
                case "padded": field = #", "vmKind": " owner ""#
                case "unsupported": field = #", "vmKind": "owner""#
                default: field = ", \"vmKind\": \"\(kind)\""
                }
                body = #"{"transport":"cmux-remote","route":"route","session":"session","trustedCarrier":true"# + field + "}"
                if kind == "failed" { status = 403 }
            case "/api/vm/vm-1/exec":
                #expect(kind == "owner" || kind == "unsupported", "Non-owner must be rejected before guest execution")
                body = kind == "unsupported" ? #"{"exitCode":0,"stdout":"{\"capabilities\":[]}"}"#
                    : #"{"exitCode":0,"stdout":"{\"capabilities\":[\"codex-external-access-v1\"]}"}"#
            // Spoofed guest state must never establish ownership, even when it looks personal.
            case "/api/vm/vm-1/fs/read": body = #"{"dataBase64":"b3duZXI="}"#
            case "/api/vm/vm-1/fs/stat":
                status = 404
                body = #"{"error":"vm_file_not_found"}"#
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
