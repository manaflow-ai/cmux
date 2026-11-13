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
    public func run(allowed: Bool, connection: DaemonConnection?, configuration: CloudConfiguration, auth: CloudAuth,
                    install: () async throws -> String?, reserved: (@MainActor (String) -> Void)? = nil) async -> [String: Any] {
        guard allowed, let connection, let platform = configuration.artifactsAPIBaseURL() else {
            return AgentPaneReply.failure(code: "cloud_disabled", message: "cloud_disabled")
        }
        // One line as it begins and one as it ends, with its time and outcome: a Send waits on the reserve
        // (cloudComposeReservation.ts), and a slow one used to leave nothing at all in the app log.
        let verb = release ? "release" : "reserve"
        let began = ContinuousClock.now
        Self.log.notice("cloud \(verb, privacy: .public): begin")
        let reply = await call(connection: connection, platform: platform, auth: auth, install: install, reserved: reserved)
        let ms = Int((ContinuousClock.now - began) / .milliseconds(1))
        let outcome = reply["ok"] as? Bool == true ? "ok" : ((reply["error"] as? [String: Any])?["code"] as? String ?? "failed")
        Self.log.notice("cloud \(verb, privacy: .public): end \(ms, privacy: .public) ms \(outcome, privacy: .public)")
        return reply
    }

    nonisolated static let log = Logger(subsystem: "com.cmuxterm.app.next", category: "app.cloud")

    /// The daemon's answer as the page's reply object: a walk of the tree it already decoded, no second decode.
    nonisolated static func object(_ answer: JSONValue) -> [String: Any] {
        func any(_ value: JSONValue) -> Any {
            switch value {
            case .null: NSNull()
            case .bool(let value): value
            case .number(let value): value.rounded() == value && abs(value) < 1e15 ? Int(value) as Any : value
            case .string(let value): value
            case .array(let items): items.map(any)
            case .object(let members): members.mapValues(any)
            }
        }
        return any(answer) as? [String: Any] ?? [:]
    }

    @MainActor
    private func call(connection: DaemonConnection, platform: URL, auth: CloudAuth, install: () async throws -> String?,
                      reserved: (@MainActor (String) -> Void)?) async -> [String: Any] {
        do {
            // The page's object with the trusted platform; Rust reads only `composeKey`, `environment` and `platform`.
            var request: [String: JSONValue] = [:]
            if case .object(let members) = params { request = members }
            request["platform"] = .string(platform.absoluteString)
            let token = try await auth.tokens().access
            let answer = try await connection.request(
                CloudStartChatReservationRequest(release: release, request: .object(request), accessToken: token, installToken: try await install() ?? ""),
                timeout: .seconds(release ? 15 : 130))
            let reply = Self.object(answer)
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
