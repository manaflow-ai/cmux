import CmuxNextCloud
import CmuxNextControl
import CmuxNextSettings
import Foundation

// `vm.agent_key.create`: what `cmux vm token create` sends from inside cmux. The app holds
// the Stack session, so the CLI never sees it: the app asks the cmux VM API (vm.cmux.dev,
// workers/cmux-vm src/api/agents.ts) for an agent key and passes the answer through. An
// agent key holds only vm:read, vm:write and vm:exec, reaches only the VMs it creates, has
// a VM count and a USD/h budget, and expires within a day; revoking it or its expiry
// deletes its VMs. The CLI stores the key in the login Keychain and never prints it, so any
// process (a plain Terminal, Claude Desktop, a script) can then run `cmux vm run` without
// this socket. Behind Labs > Show Preview Features while the token flow is being shaped.
extension AppControl {
    func registerVMAgentKeyMethods(_ services: AppServices) {
        service?.router.register([
            ControlMethod.async("vm.agent_key.create") { call in
                let issuer = try await Self.vmIssuer(services)
                let planned = try Self.vmAgentKeyRequest(backend: issuer.backend, params: call.params)
                // A runtime selection names its own VM API; else the one Rust names for the backend.
                guard let baseURL = issuer.vmOrigin ?? URL(string: planned.baseUrl),
                      let url = issuer.vmOrigin.map({ $0.appendingPathComponent(planned.path) }) ?? URL(string: planned.url)
                else {
                    throw ControlError(code: "internal", message: "the cmux VM API address is invalid")
                }
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                // timeout: a VM API that never answers; the CLI waits on this call (Rust's 20 s, as before).
                request.timeoutInterval = TimeInterval(planned.timeoutSeconds)
                request.setValue("application/json", forHTTPHeaderField: "content-type")
                request.setValue("Bearer \(issuer.accessToken)", forHTTPHeaderField: "authorization")
                request.setValue(issuer.teamID, forHTTPHeaderField: "x-cmux-team-id")
                request.httpBody = try JSONEncoder().encode(planned.body)
                // No answer at all is status 0, which Rust reads as unreachable.
                let answer = try? await URLSession.shared.data(for: request)
                let status = (answer?.1 as? HTTPURLResponse)?.statusCode ?? 0
                return try Self.vmAgentKeyAnswer(status: status, body: answer?.0 ?? Data(), baseURL: baseURL, teamID: issuer.teamID)
            }.withDeadline(.fixed(.seconds(25))),
        ])
    }

    struct VMIssuer: Sendable {
        var backend: CloudConfiguration.Backend
        /// The runtime selection's VM API, which wins over the backend's.
        var vmOrigin: URL?
        var teamID: String
        var accessToken: String
    }

    /// The signed-in session and its team, behind the Cloud policy (not Labs, Leo 2026-10-30).
    nonisolated static func vmIssuer(_ services: AppServices) async throws -> VMIssuer {
        let (cloud, backend, vmOrigin) = try await MainActor.run { () throws -> (CloudService, CloudConfiguration.Backend, URL?) in
            if let refusal = ControlError.policyRefusal("vm.agent_key.create", disabled: services.registry.disabledFeatures) { throw refusal }
            guard services.cloud.mayCallCloud else { throw ControlError(code: "cloud_disabled", message: Self.vmText(.cloudUnavailable)) }
            guard services.cloud.isSignedIn else { throw ControlError(code: "not_signed_in", message: Self.vmText(.notSignedIn)) }
            let configuration = services.cloud.configuration
            return (services.cloud, configuration.backend, configuration.runtimeSelection?.vmOrigin)
        }
        guard let teamID = await MainActor.run(body: { cloud.auth.teamID }), !teamID.isEmpty else {
            throw ControlError(code: "no_team", message: Self.vmText(.noTeam))
        }
        let access: String
        do {
            access = try await cloud.auth.tokens().access
        } catch {
            throw ControlError(code: "not_signed_in", message: Self.vmText(.notSignedIn))
        }
        return VMIssuer(backend: backend, vmOrigin: vmOrigin, teamID: teamID, accessToken: access)
    }

    // The mint's rules are Rust's (cmux-cloud-config agent_key, the same ones `cmux vm token
    // create` links), asked over the app FFI's JSON channel: the body and its limits, the VM API
    // for the backend, and how the answer reads. The app only does the HTTP call.

    nonisolated struct VMAgentKeyPlan: Decodable, Sendable {
        var url: String
        var baseUrl: String
        var body: JSONValue
        var timeoutSeconds: Int

        /// The mint's path under a VM API: `url` past `baseUrl`.
        var path: String { String(url.dropFirst(baseUrl.count + 1)) }
    }

    nonisolated struct VMAgentKeyRefusal: Decodable, Sendable {
        var code: String
        var message: String
        var status: Int?
        var appText: String?
    }

    /// The request body and the VM API for `backend`, or the refusal of a bad limit.
    nonisolated static func vmAgentKeyRequest(backend: CloudConfiguration.Backend, params: [String: JSONValue]) throws -> VMAgentKeyPlan {
        struct Request: Encodable {
            var backend: [String: String]
            var params: [String: JSONValue]
        }
        struct Reply: Decodable {
            var request: VMAgentKeyPlan?
            var refusal: VMAgentKeyRefusal?
        }
        let wire: [String: String] = switch backend {
        case .production: ["kind": "production"]
        case let .development(url): ["kind": "development", "url": url.absoluteString]
        case let .localOnly(url): ["kind": "localOnly", "url": url.absoluteString]
        }
        let reply = CloudStartCore().call("cloud_vm_agent_key_request", Request(backend: wire, params: params), as: Reply.self)
        if let plan = reply?.request { return plan }
        throw reply?.refusal.map(vmAgentKeyError) ?? vmRulesUnavailable
    }

    /// The VM API's answer (`status` 0: none) as the socket's result: its fields plus `baseUrl`
    /// and `teamId`, so the CLI stores the key with the service and team it works at.
    nonisolated static func vmAgentKeyAnswer(status: Int, body: Data, baseURL: URL, teamID: String) throws -> JSONValue {
        struct Request: Encodable {
            var status: Int
            var body: String
            var baseUrl: String
            var teamId: String
        }
        struct Reply: Decodable {
            var result: JSONValue?
            var refusal: VMAgentKeyRefusal?
        }
        let request = Request(status: status, body: String(decoding: body, as: UTF8.self), baseUrl: baseURL.absoluteString, teamId: teamID)
        // A VM API answer is small; 64 KiB fits one without a retry.
        guard let data = try? JSONEncoder().encode(request),
              let replyData = CloudStartCore().callData("cloud_vm_agent_key_answer", data, startingCapacity: 1 << 16),
              let reply = try? JSONDecoder().decode(Reply.self, from: replyData)
        else { throw vmRulesUnavailable }
        if let result = reply.result { return result }
        throw reply.refusal.map(vmAgentKeyError) ?? vmRulesUnavailable
    }

    /// A refusal as this socket's error, in the app's own words where Rust names them. The key is never in it.
    nonisolated static func vmAgentKeyError(_ refusal: VMAgentKeyRefusal) -> ControlError {
        let message = switch refusal.appText {
        case "notSignedIn": Self.vmText(.notSignedIn)
        case "unreachable": Self.vmText(.unreachable)
        default: refusal.message
        }
        return ControlError(code: refusal.code, message: message, data: refusal.status.map { .object(["status": JSONValue($0)]) })
    }

    nonisolated static var vmRulesUnavailable: ControlError {
        ControlError(code: "internal", message: "the app's cmux VM rules did not answer")
    }

    enum VMText { case notSignedIn, noTeam, unreachable, cloudUnavailable }

    nonisolated static func vmText(_ text: VMText) -> String {
        switch text {
        case .notSignedIn:
            String(localized: "runs.error.notSignedIn", defaultValue: "Sign in to cmux first: run `cmux cloud sign-in`, or choose Sign In in the cmux app.", table: "Runs", bundle: .module)
        case .noTeam:
            String(localized: "vm.token.error.noTeam", defaultValue: "Choose a cmux team in the cmux app first.", table: "Runs", bundle: .module)
        case .unreachable:
            String(localized: "vm.token.error.unreachable", defaultValue: "The cmux VM service didn't answer. Try again in a moment.", table: "Runs", bundle: .module)
        case .cloudUnavailable:
            String(localized: "runs.error.cloudUnavailable", defaultValue: "cmux Cloud is not available for this account or team.", table: "Runs", bundle: .module)
        }
    }
}
