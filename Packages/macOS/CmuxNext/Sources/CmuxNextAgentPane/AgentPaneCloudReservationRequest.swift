public import CmuxNextCloud
public import CmuxNextDaemon
public import Foundation
import os

/// Transparent native envelope; shared web owns compose lifetime and Rust owns the API calls.
public nonisolated struct AgentPaneCloudReservationRequest: Equatable, Sendable {
    public static let methods: Set<String> = ["cloud.reserve", "cloud.releaseReservation"]
    public let release: Bool
    public let params: JSONValue
    public let composeKey: String?
    /// The folder, agent and model the Send would start with, read before a machine is reserved (+BeforeLease).
    public let cwd: String?, harness: String?, model: String?

    init?(method: String, params: [String: Any]?) {
        guard Self.methods.contains(method),
              let data = try? JSONSerialization.data(withJSONObject: params ?? [:]),
              var params = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        release = method == "cloud.releaseReservation"
        composeKey = params["composeKey"]?.stringValue
        cwd = params["cwd"]?.stringValue.flatMap { $0.hasPrefix("/") ? $0 : nil }
        harness = params["harness"]?.stringValue
        model = params["model"]?.stringValue
        if case .object(let object) = params { params = .object(object.filter { !["cwd", "harness", "model"].contains($0.key) }) } // the app's checks only, never Rust's request
        self.params = params
    }

    /// Supplies only the native client's trusted platform and human-session credentials to Rust. `install` is the
    /// install token: Rust names the reservation in its team, the one the machine list reads and the spare warm uses.
    /// `reserved`: told the machine a reserve answered, so its login copy starts on that exact machine.
    /// No machine is reserved for a Send that will be refused (the App's +Machine checks it again at Send): `cwd` this Mac
    /// doesn't trust (`link start-chat trust` from the acpmux at `acpmuxHome`, the copy's), or an agent `agentRefused`
    /// says cannot run (a used-up Claude limit). The page then sends without a reservation, and the Send says why.
    @MainActor
    public func run(allowed: Bool, binary: URL?, configuration: CloudConfiguration, auth: CloudAuth,
                    install: () async throws -> String?, reserved: (@MainActor (String) -> Void)? = nil,
                    acpmuxHome: String? = nil, agentRefused: ((String?, String?) async -> Bool)? = nil) async -> [String: Any] {
        guard allowed, let binary, let platform = configuration.artifactsAPIBaseURL() else {
            return AgentPaneReply.failure(code: "cloud_disabled", message: "cloud_disabled")
        }
        if !release, let code = await refusal(binary: binary, acpmuxHome: acpmuxHome, agentRefused: agentRefused) {
            Self.log.notice("cloud reserve: none, the Send would be refused (\(code, privacy: .public))")
            return AgentPaneReply.failure(code: code, message: code)
        }
        // One line as it begins and one as it ends, with its time and outcome: a Send waits on the reserve
        // (cloudComposeReservation.ts), and a slow one used to leave nothing at all in the app log.
        let verb = release ? "release" : "reserve"
        let began = ContinuousClock.now
        Self.log.notice("cloud \(verb, privacy: .public): begin")
        let reply = await call(binary: binary, platform: platform, auth: auth, install: install, reserved: reserved)
        let ms = Int((ContinuousClock.now - began) / .milliseconds(1))
        let outcome = reply["ok"] as? Bool == true ? "ok" : ((reply["error"] as? [String: Any])?["code"] as? String ?? "failed")
        Self.log.notice("cloud \(verb, privacy: .public): end \(ms, privacy: .public) ms \(outcome, privacy: .public)")
        return reply
    }

    /// The code of ``run(allowed:binary:configuration:auth:install:reserved:acpmuxHome:agentRefused:)``'s refusal, or nil.
    private func refusal(binary: URL, acpmuxHome: String?, agentRefused: ((String?, String?) async -> Bool)?) async -> String? {
        if let cwd, let acpmuxHome, let level = await CloudMoveCLI(binary: binary, timeout: .seconds(15)).startChatTrust(folder: cwd, acpmuxHome: acpmuxHome),
           level != "trusted" { return Self.untrustedSource }
        return await agentRefused?(harness, model) == true ? "agent_unavailable" : nil
    }

    /// AgentRemoteStartRefusal.untrustedSourceCode (CmuxNextDaemonService, which this package sits under).
    static let untrustedSource = "app.untrusted_source"

    nonisolated static let log = Logger(subsystem: "com.cmuxterm.app.next", category: "app.cloud")

    @MainActor
    private func call(binary: URL, platform: URL, auth: CloudAuth, install: () async throws -> String?,
                      reserved: (@MainActor (String) -> Void)?) async -> [String: Any] {
        do {
            let data = try JSONEncoder().encode(params)
            var object = (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            object["platform"] = platform.absoluteString
            let payload = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            let token = try await auth.tokens().access
            let answer = try await CloudMoveCLI(binary: binary).startChatReservation(
                release: release, request: String(decoding: payload, as: UTF8.self), access: token, install: try await install())
            let reply = try JSONSerialization.jsonObject(with: answer) as? [String: Any] ?? [:]
            guard reply["ok"] as? Bool == true else {
                // Rust emits only its fixed error codes; provider messages never reach the page.
                let code = reply["error_code"] as? String ?? "unavailable"
                return AgentPaneReply.failure(code: code, message: code)
            }
            if !release, let reserved, let machine = CloudMoveCLI.reservedMachine(reply) { reserved(machine) }
            return AgentPaneReply.success(reply)
        } catch {
            return AgentPaneReply.failure(code: "unavailable", message: "unavailable")
        }
    }
}
