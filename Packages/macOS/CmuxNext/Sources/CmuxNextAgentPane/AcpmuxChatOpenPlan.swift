public import Foundation

/// The daemon's `_acpmux/chat_open` result, reduced to one client action.
public nonisolated struct AcpmuxChatOpenPlan: Sendable, Equatable {
    public enum Action: Sendable, Equatable {
        case needsFolder(reason: String)
        case adopt(adopt: AgentPaneAdopt, cwd: String?, sessionNew: Data)
        case terminal(argv: [String], env: [String: String], cwd: String?)
        case readOnly(path: String)
    }

    public let action: Action
    /// The chat's acpmux family (`claude`, `codex`, `opencode`) when the daemon says; the adopt's
    /// harness is a profile, named freely.
    public var family: String?
    /// The chat itself (title, folder, harness) as acpmux's index holds it, nil from an older
    /// daemon: the app names the chat it opens without a copy of the index.
    public var chat: AcpmuxChat?

    public init?(result: [String: Any]) {
        chat = (result["chat"] as? [String: Any]).flatMap(AcpmuxChat.init(json:))
        if let needsFolder = result["needsFolder"] as? [String: Any], let reason = needsFolder["reason"] as? String {
            action = .needsFolder(reason: reason)
            family = result["family"] as? String
            return
        }
        let cwd = result["cwd"] as? String
        family = result["family"] as? String
        switch result["kind"] as? String {
        case "adopt":
            guard let adoptValue = result["adopt"] as? [String: Any],
                  let harness = adoptValue["harness"] as? String,
                  let agentSessionID = adoptValue["agentSessionId"] as? String,
                  let sessionNew = result["sessionNew"],
                  JSONSerialization.isValidJSONObject(sessionNew) else { return nil }
            guard let data = try? JSONSerialization.data(withJSONObject: sessionNew) else { return nil }
            action = .adopt(adopt: AgentPaneAdopt(harness: harness, agentSessionId: agentSessionID), cwd: cwd, sessionNew: data)
        case "terminal":
            guard let terminal = result["terminal"] as? [String: Any], let argv = terminal["argv"] as? [String], !argv.isEmpty else { return nil }
            let env = terminal["env"] as? [String: String] ?? [:]
            action = .terminal(argv: argv, env: env, cwd: cwd)
        case "readOnly":
            guard let value = result["readOnly"] as? [String: Any], let path = value["path"] as? String, !path.isEmpty else { return nil }
            action = .readOnly(path: path)
        default: return nil
        }
    }
}
