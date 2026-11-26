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
    /// The page's empty local chat the compose's Send would replace (webviews App.tsx `emptyLocalChat`, the
    /// same id `cloud.startChat` sends as `replacesChat`): the pane reserves for it only while it shows that
    /// chat (``AgentPaneModel/reserveReplaces(_:)``). Nil: a compose with no chat. Never forwarded to Rust.
    public let replacesChat: String?
    /// The page asks at its composer's open, with no gesture (cloudComposeReservation.ts `opened`): the pane
    /// takes it only under ``AgentPaneCloudLeaseOnOpenFlag`` (``AgentPaneModel/takeCloudOpenLease(_:)``). Never forwarded to Rust.
    public let atOpen: Bool
    /// The page reserves for Auto (AutoCloud) picked on its New Tab page, not Cloud (cloudComposeReservation.ts
    /// `auto`): only the log line says so. Never forwarded to Rust.
    public let auto: Bool

    init?(method: String, params: [String: Any]?) {
        var object = params ?? [:]
        let replaces = object.removeValue(forKey: "replacesChat")
        let atOpen = object.removeValue(forKey: "atOpen")
        let auto = object.removeValue(forKey: "auto")
        if let atOpen, !(atOpen is Bool) { return nil }
        if let auto, !(auto is Bool) { return nil }
        if let replaces, !((replaces as? String).map { !$0.isEmpty && $0.count <= 128 } ?? false) { return nil }
        guard Self.methods.contains(method),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let params = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        release = method == "cloud.releaseReservation"
        self.params = params
        composeKey = params["composeKey"]?.stringValue
        replacesChat = replaces as? String
        self.atOpen = atOpen as? Bool ?? false
        self.auto = auto as? Bool ?? false
    }

    /// Supplies only the native client's trusted platform and human-session credentials to Rust. `install` is the
    /// install token: Rust names the reservation in its team, the one the machine list reads and the spare warm uses.
    /// `reserved`: told the machine a reserve answered, so its login copy starts on that exact machine.
    @MainActor
    public func run(allowed: Bool, binary: URL?, configuration: CloudConfiguration, auth: CloudAuth,
                    install: () async throws -> String?, reserved: (@MainActor (String) -> Void)? = nil) async -> [String: Any] {
        guard allowed, let binary, let platform = configuration.artifactsAPIBaseURL() else {
            return AgentPaneReply.failure(code: "cloud_disabled", message: "cloud_disabled")
        }
        // One line as it begins and one as it ends, with its time and outcome: a Send waits on the reserve
        // (cloudComposeReservation.ts), and a slow one used to leave nothing at all in the app log.
        let verb = release ? "release" : (atOpen ? "reserve at open" : "reserve") + (auto ? " for auto" : "")
        let began = ContinuousClock.now
        Self.log.notice("cloud \(verb, privacy: .public): begin")
        let reply = await call(binary: binary, platform: platform, auth: auth, install: install, reserved: reserved)
        let ms = Int((ContinuousClock.now - began) / .milliseconds(1))
        let outcome = reply["ok"] as? Bool == true ? "ok" : ((reply["error"] as? [String: Any])?["code"] as? String ?? "failed")
        Self.log.notice("cloud \(verb, privacy: .public): end \(ms, privacy: .public) ms \(outcome, privacy: .public)")
        return reply
    }

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

extension AgentPaneModel {
    /// A reserve for the pane's empty local chat (``AgentPaneCloudReservationRequest/replacesChat``), taken under
    /// the checks `cloud.startChat` applies to a start replacing that chat (``AgentPaneHandOff``'s `cloudChecked`
    /// and `held`): a Cloud start runner, a chat on this Mac, the pane showing that very chat, and no start or open
    /// of another chat out in it (a harness switch), whose session would replace the chat the reserve names.
    func reserveReplaces(_ chat: String?) -> Bool {
        guard let chat, chat == sessionId, onCloudStartChat != nil, !chatIsElsewhere else { return false }
        return transport.replacements.admits(replacingOpened: true)
    }
}
