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
                let body = try ControlMethod.vmAgentKeyRequest(call.params)
                var request = URLRequest(url: issuer.baseURL.appendingPathComponent("v1/agent-keys"))
                request.httpMethod = "POST"
                request.timeoutInterval = 20
                request.setValue("application/json", forHTTPHeaderField: "content-type")
                request.setValue("Bearer \(issuer.accessToken)", forHTTPHeaderField: "authorization")
                request.setValue(issuer.teamID, forHTTPHeaderField: "x-cmux-team-id")
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                let data: Data
                let response: URLResponse
                do {
                    (data, response) = try await URLSession.shared.data(for: request)
                } catch {
                    throw ControlError(code: "unavailable", message: Self.vmText(.unreachable))
                }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                let answer = try? JSONValue.parse(data)
                guard (200..<300).contains(status), case .object(var fields)? = answer, fields["key"]?.stringValue != nil else {
                    throw Self.vmAgentKeyError(status: status, answer: answer)
                }
                // Where the key works, so the CLI stores it with its own base URL and team.
                fields["baseUrl"] = .string(issuer.baseURL.absoluteString)
                fields["teamId"] = .string(issuer.teamID)
                return .object(fields)
            }.withDeadline(.fixed(.seconds(25))),
        ])
    }

    struct VMIssuer: Sendable {
        var baseURL: URL
        var teamID: String
        var accessToken: String
    }

    /// The signed-in session and its team, behind the Cloud policy (not Labs, Leo 2026-10-30).
    nonisolated static func vmIssuer(_ services: AppServices) async throws -> VMIssuer {
        let (cloud, baseURL) = try await MainActor.run { () throws -> (CloudService, URL) in
            if let refusal = ControlError.policyRefusal("vm.agent_key.create", disabled: services.registry.disabledFeatures) { throw refusal }
            guard services.cloud.mayCallCloud else { throw ControlError(code: "cloud_disabled", message: Self.vmText(.cloudUnavailable)) }
            guard services.cloud.isSignedIn else { throw ControlError(code: "not_signed_in", message: Self.vmText(.notSignedIn)) }
            guard let baseURL = Self.vmBaseURL(services.cloud.configuration.backend) else {
                throw ControlError(code: "internal", message: "the cmux VM API address is invalid")
            }
            return (services.cloud, baseURL)
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
        return VMIssuer(baseURL: baseURL, teamID: teamID, accessToken: access)
    }

    /// The cmux VM API for this build's Cloud: production's for production, staging's for a
    /// development stack. There is no override: the app sends its Stack session only there.
    nonisolated static func vmBaseURL(_ backend: CloudConfiguration.Backend) -> URL? {
        switch backend {
        case .production: return URL(string: "https://vm.cmux.dev")
        case .development, .localOnly: return URL(string: "https://vm-staging.cmux.dev")
        }
    }

    /// A refusal from the cmux VM API as this socket's error. The key is never in it.
    nonisolated static func vmAgentKeyError(status: Int, answer: JSONValue?) -> ControlError {
        let message = answer?["message"]?.stringValue.map { String($0.prefix(300)) } ?? "HTTP \(status)"
        switch status {
        case 401: return ControlError(code: "not_signed_in", message: Self.vmText(.notSignedIn))
        case 402: return ControlError(code: "plan_required", message: message)
        case 403: return ControlError(code: "forbidden", message: message)
        case 400: return ControlError(code: "invalid_params", message: message)
        case 429: return ControlError(code: "rate_limited", message: message)
        default: return ControlError(code: "unavailable", message: message, data: .object(["status": .number(Double(status))]))
        }
    }

    enum VMText { case notSignedIn, noTeam, unreachable, cloudUnavailable }

    nonisolated static func vmText(_ text: VMText) -> String {
        switch text {
        case .notSignedIn:
            String(localized: "runs.error.notSignedIn", defaultValue: "Sign in to cmux in the cmux app first.", table: "Runs", bundle: .module)
        case .noTeam:
            String(localized: "vm.token.error.noTeam", defaultValue: "Choose a cmux team in the cmux app first.", table: "Runs", bundle: .module)
        case .unreachable:
            String(localized: "vm.token.error.unreachable", defaultValue: "The cmux VM service didn't answer. Try again in a moment.", table: "Runs", bundle: .module)
        case .cloudUnavailable:
            String(localized: "runs.error.cloudUnavailable", defaultValue: "cmux Cloud is not available for this account or team.", table: "Runs", bundle: .module)
        }
    }
}
