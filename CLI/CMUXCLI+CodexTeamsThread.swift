import Foundation

extension CMUXCLI {
    struct CodexTeamsSpawn {
        let parentThreadId: String
        let sourceDepth: Int?
        let agentNickname: String?
        let agentRole: String?
    }

    struct CodexTeamsThread {
        let id: String
        let cwd: String?
        let statusType: String?
        let agentNickname: String?
        let agentRole: String?
        let spawn: CodexTeamsSpawn?
    }

    static func codexTeamsThread(from object: [String: Any]) -> CodexTeamsThread? {
        guard let id = object["id"] as? String, !id.isEmpty else { return nil }
        return CodexTeamsThread(
            id: id,
            cwd: object["cwd"] as? String,
            statusType: codexTeamsStatusType(from: object),
            agentNickname: object["agentNickname"] as? String,
            agentRole: object["agentRole"] as? String,
            spawn: codexTeamsSpawn(from: object)
        )
    }

    static func codexTeamsStatusType(from threadObject: [String: Any]) -> String? {
        guard let status = threadObject["status"] as? [String: Any] else {
            return nil
        }
        return status["type"] as? String
    }

    static func codexTeamsThreadMayBeAttachable(_ thread: CodexTeamsThread) -> Bool {
        guard let statusType = thread.statusType?.trimmingCharacters(in: .whitespacesAndNewlines),
              !statusType.isEmpty else {
            return false
        }
        let normalized = statusType
            .replacingOccurrences(of: "_", with: "")
            .lowercased()
        return normalized != "notloaded"
    }

    static func codexTeamsSpawn(from threadObject: [String: Any]) -> CodexTeamsSpawn? {
        guard let source = threadObject["source"] as? [String: Any] else { return nil }
        let subagentSource = source["subAgent"] ?? source["subagent"]
        guard let subagent = subagentSource as? [String: Any] else { return nil }
        let spawnSource = subagent["thread_spawn"] ?? subagent["threadSpawn"]
        guard let spawn = spawnSource as? [String: Any],
              let parentThreadId = (spawn["parent_thread_id"] as? String) ?? (spawn["parentThreadId"] as? String),
              !parentThreadId.isEmpty else {
            return nil
        }

        let sourceDepth: Int?
        if let depth = spawn["depth"] as? Int {
            sourceDepth = depth
        } else if let depth = spawn["depth"] as? NSNumber {
            sourceDepth = depth.intValue
        } else {
            sourceDepth = nil
        }

        return CodexTeamsSpawn(
            parentThreadId: parentThreadId,
            sourceDepth: sourceDepth,
            agentNickname: spawn["agent_nickname"] as? String ?? spawn["agentNickname"] as? String,
            agentRole: spawn["agent_role"] as? String ?? spawn["agentRole"] as? String
        )
    }

}
