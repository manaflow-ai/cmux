public import CmuxNextCloud
public import CmuxNextDaemon
public import Foundation

/// Transparent native envelope; shared web owns compose lifetime and Rust owns the API calls.
public nonisolated struct AgentPaneCloudReservationRequest: Equatable, Sendable {
    public static let methods: Set<String> = ["cloud.reserve", "cloud.releaseReservation"]
    public let release: Bool
    public let params: JSONValue
    public let composeKey: String?

    init?(method: String, params: [String: Any]?) {
        guard Self.methods.contains(method),
              let data = try? JSONSerialization.data(withJSONObject: params ?? [:]),
              let params = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        release = method == "cloud.releaseReservation"
        self.params = params
        composeKey = params["composeKey"]?.stringValue
    }

    /// Supplies only the native client's trusted platform and human-session credentials to Rust. `install` is the
    /// install token: Rust names the reservation in its team, the one the machine list reads and the spare warm uses.
    /// `reserved`: told the machine a reserve answered, so its login copy starts on that exact machine.
    @MainActor
    public func run(allowed: Bool, binary: URL?, configuration: CloudConfiguration, auth: CloudAuth,
                    install: () async throws -> String?, reserved: @MainActor (String) -> Void = { _ in }) async -> [String: Any] {
        guard allowed, let binary, let platform = configuration.artifactsAPIBaseURL() else {
            return AgentPaneReply.failure(code: "cloud_disabled", message: "cloud_disabled")
        }
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
            if !release, let machine = CloudMoveCLI.reservedMachine(reply) { reserved(machine) }
            return AgentPaneReply.success(reply)
        } catch {
            return AgentPaneReply.failure(code: "unavailable", message: "unavailable")
        }
    }
}
