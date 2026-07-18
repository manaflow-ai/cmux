import Foundation

public enum CopilotHookConfig {
    public struct Event: Equatable, Sendable {
        public var name: String
        public var command: String
        public var timeoutSeconds: Int

        public init(name: String, command: String, timeoutSeconds: Int) {
            self.name = name
            self.command = command
            self.timeoutSeconds = timeoutSeconds
        }
    }

    public struct RemovalResult {
        public var data: Data?
        public var removedCount: Int

        public init(data: Data?, removedCount: Int) {
            self.data = data
            self.removedCount = removedCount
        }
    }

    public enum ConfigError: Error, Equatable {
        case invalidJSON
        case invalidHooks
        case invalidEvent(String)
    }

    public static func installing(
        events: [Event],
        in existing: Data?,
        isOwnedCommand: (String) -> Bool
    ) throws -> Data {
        var root = try rootObject(from: existing)
        var hooks = try hooksObject(from: root)
        _ = try removeOwnedHooks(from: &hooks, isOwnedCommand: isOwnedCommand)

        for event in events {
            guard !event.name.isEmpty, !event.command.isEmpty else { continue }
            var entries = try eventEntries(named: event.name, in: hooks)
            entries.append([
                "type": "command",
                "command": event.command,
                "timeoutSec": max(event.timeoutSeconds, 1),
            ] as [String: Any])
            hooks[event.name] = entries
        }

        root["version"] = 1
        root["hooks"] = hooks
        return try serialized(root)
    }

    public static func uninstalling(
        from existing: Data,
        isOwnedCommand: (String) -> Bool
    ) throws -> RemovalResult {
        var root = try rootObject(from: existing)
        var hooks = try hooksObject(from: root)
        let removedCount = try removeOwnedHooks(from: &hooks, isOwnedCommand: isOwnedCommand)
        if hooks.isEmpty {
            root.removeValue(forKey: "hooks")
        } else {
            root["hooks"] = hooks
        }

        let remainingKeys = Set(root.keys)
        let data = remainingKeys.isEmpty || remainingKeys == ["version"]
            ? nil
            : try serialized(root)
        return RemovalResult(data: data, removedCount: removedCount)
    }

    /// Removes cmux-owned entries from an older Copilot settings/config file
    /// without changing its schema or adding a version field.
    public static func removingOwnedHooks(
        from existing: Data,
        isOwnedCommand: (String) -> Bool
    ) throws -> RemovalResult {
        var root = try rootObject(from: existing)
        var hooks = try hooksObject(from: root)
        let removedCount = try removeOwnedHooks(from: &hooks, isOwnedCommand: isOwnedCommand)
        if hooks.isEmpty {
            root.removeValue(forKey: "hooks")
        } else {
            root["hooks"] = hooks
        }
        return RemovalResult(
            data: root.isEmpty ? nil : try serialized(root),
            removedCount: removedCount
        )
    }

    private static func rootObject(from data: Data?) throws -> [String: Any] {
        guard let data, !data.isEmpty else { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any] else {
            throw ConfigError.invalidJSON
        }
        return root
    }

    private static func hooksObject(from root: [String: Any]) throws -> [String: Any] {
        guard let rawHooks = root["hooks"] else { return [:] }
        guard let hooks = rawHooks as? [String: Any] else {
            throw ConfigError.invalidHooks
        }
        return hooks
    }

    private static func eventEntries(named name: String, in hooks: [String: Any]) throws -> [[String: Any]] {
        guard let rawEntries = hooks[name] else { return [] }
        guard let entries = rawEntries as? [[String: Any]] else {
            throw ConfigError.invalidEvent(name)
        }
        return entries
    }

    private static func removeOwnedHooks(
        from hooks: inout [String: Any],
        isOwnedCommand: (String) -> Bool
    ) throws -> Int {
        var removedCount = 0
        for eventName in Array(hooks.keys) {
            guard var entries = hooks[eventName] as? [[String: Any]] else {
                throw ConfigError.invalidEvent(eventName)
            }
            var rewrittenEntries: [[String: Any]] = []
            for var entry in entries {
                if let command = entry["command"] as? String, isOwnedCommand(command) {
                    removedCount += 1
                    continue
                }
                if let rawNestedHooks = entry["hooks"] {
                    guard var nestedHooks = rawNestedHooks as? [[String: Any]] else {
                        throw ConfigError.invalidEvent(eventName)
                    }
                    let before = nestedHooks.count
                    nestedHooks.removeAll { hook in
                        guard let command = hook["command"] as? String else { return false }
                        return isOwnedCommand(command)
                    }
                    removedCount += before - nestedHooks.count
                    if nestedHooks.isEmpty {
                        continue
                    }
                    entry["hooks"] = nestedHooks
                }
                rewrittenEntries.append(entry)
            }
            entries = rewrittenEntries
            if entries.isEmpty {
                hooks.removeValue(forKey: eventName)
            } else {
                hooks[eventName] = entries
            }
        }
        return removedCount
    }

    private static func serialized(_ root: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(root) else {
            throw ConfigError.invalidJSON
        }
        return try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys]
        )
    }
}
