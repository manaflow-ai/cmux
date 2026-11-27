import CmuxNextCloud
import CmuxNextControl
import CmuxNextSettings
import Foundation

// `vm.agent_key.create`: what `cmux vm token create` sends from inside cmux. The app holds
// the Stack session, so the CLI never sees it: the app runs `cmux cloud vm-agent-key-mint`
// (cmux-tui `cli/cloud_vm_agent_key.rs`) with it, which asks the cmux VM API (vm.cmux.dev,
// workers/cmux-vm src/api/agents.ts) for an agent key, and passes the answer through. An
// agent key holds only vm:read, vm:write and vm:exec, reaches only the VMs it creates, has
// a VM count and a USD/h budget, and expires within a day; revoking it or its expiry
// deletes its VMs. The CLI stores the key in the login Keychain and never prints it, so any
// process (a plain Terminal, Claude Desktop, a script) can then run `cmux vm run` without
// this socket. The body, the VM API and how the answer reads are Rust's (cmux-cloud-config
// agent_key); the app only hands over its session, team and Cloud.
extension AppControl {
    func registerVMAgentKeyMethods(_ services: AppServices) {
        service?.router.register([
            ControlMethod.async("vm.agent_key.create") { [mint = CloudCLICall(cli: services.bundledCLI)] call in
                let stdin = try await Self.vmAgentKeyEnvelope(services, params: call.params)
                let silent = ControlError(code: "internal", message: "the app's cmux VM rules did not answer")
                // timeout: the mint's own 20 s bound plus the child's start; the CLI waits on this call.
                guard let line = try? await mint.run(["cloud", "vm-agent-key-mint"], stdin: stdin, timeout: .seconds(23)),
                      let reply = try? JSONDecoder().decode(VMAgentKeyReply.self, from: line) else { throw silent }
                if let value = reply.value { return value }
                throw reply.error.map(Self.vmAgentKeyError) ?? silent
            }.withDeadline(.fixed(.seconds(25))),
        ])
    }

    /// The mint's stdin: the signed-in session and its team, behind the Cloud policy (not Labs, Leo
    /// 2026-10-30), with this build's backend and the runtime selection's VM API.
    nonisolated static func vmAgentKeyEnvelope(_ services: AppServices, params: [String: JSONValue]) async throws -> Data {
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
        guard let access = try? await cloud.auth.tokens().access else {
            throw ControlError(code: "not_signed_in", message: Self.vmText(.notSignedIn))
        }
        let wire: [String: String] = switch backend {
        case .production: ["kind": "production"]
        case let .development(url): ["kind": "development", "url": url.absoluteString]
        case let .localOnly(url): ["kind": "localOnly", "url": url.absoluteString]
        }
        let envelope: JSONValue = .object(["backend": .object(wire.mapValues(JSONValue.string)), "vmOrigin": vmOrigin.map { .string($0.absoluteString) } ?? .null,
                                           "credential": .string(access), "teamId": .string(teamID), "params": .object(params)])
        return try JSONEncoder().encode(envelope)
    }

    nonisolated private struct VMAgentKeyReply: Decodable, Sendable {
        var value: JSONValue?
        var error: VMAgentKeyRefusal?
    }

    nonisolated struct VMAgentKeyRefusal: Decodable, Sendable {
        var code: String
        var message: String
        var status: Int?
        var appText: String?
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

    enum VMText { case notSignedIn, noTeam, unreachable, cloudUnavailable }

    nonisolated static func vmText(_ text: VMText) -> String {
        switch text {
        case .notSignedIn:
            String(localized: "runs.error.notSignedIn", defaultValue: "Sign in to cmux first: run `cmux cloud sign-in`, or choose Sign In in the cmux app.", table: "Runs", bundle: .module.inAppLanguage)
        case .noTeam:
            String(localized: "vm.token.error.noTeam", defaultValue: "Choose a cmux team in the cmux app first.", table: "Runs", bundle: .module.inAppLanguage)
        case .unreachable:
            String(localized: "vm.token.error.unreachable", defaultValue: "The cmux VM service didn't answer. Try again in a moment.", table: "Runs", bundle: .module.inAppLanguage)
        case .cloudUnavailable:
            String(localized: "runs.error.cloudUnavailable", defaultValue: "cmux Cloud is not available for this account or team.", table: "Runs", bundle: .module.inAppLanguage)
        }
    }
}
