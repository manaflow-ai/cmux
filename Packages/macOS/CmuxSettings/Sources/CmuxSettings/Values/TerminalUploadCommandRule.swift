import Foundation
import os

nonisolated private let terminalUploadCommandRuleLogger = Logger(
    subsystem: "com.cmuxterm.app",
    category: "TerminalUploadCommand"
)

/// A single host-scoped upload-command rule stored under `terminal.uploadCommands`
/// in `cmux.json`. When the terminal uploads a dropped/pasted file to a remote
/// target, cmux runs the first rule whose `hostPattern` matches the ssh
/// destination **instead of** the built-in `scp`, then inserts the command's
/// stdout (or the remote path it chose, if the command prints nothing). A rule
/// with no `hostPattern` matches every remote host.
///
/// Semantics mirror `~/.ssh/config` `Host` blocks: a glob pattern (`*`, `?` via
/// `fnmatch`), **first match wins**, no match → the built-in `scp` transport.
public struct TerminalUploadCommandRule: Codable, Sendable, Equatable, Hashable {
    public var hostPattern: String?
    public var command: String
    public var enabled: Bool

    private enum CodingKeys: String, CodingKey {
        case hostPattern
        case command
        case enabled
    }

    public init(hostPattern: String? = nil, command: String, enabled: Bool = true) {
        self.hostPattern = hostPattern
        self.command = command
        self.enabled = enabled
    }

    public init(from decoder: Decoder) throws {
        // Reject unknown keys so a typo (e.g. "hostpattern" or "enable") can't
        // silently change behavior — matches the schema's additionalProperties:false
        // and keeps a mistyped rule fail-closed rather than an accidental catch-all.
        let rawKeys = try decoder.container(keyedBy: AnyCodingKey.self)
        let knownKeys: Set<String> = ["hostPattern", "command", "enabled"]
        if let unknown = rawKeys.allKeys.first(where: { !knownKeys.contains($0.stringValue) }) {
            throw DecodingError.dataCorruptedError(
                forKey: unknown,
                in: rawKeys,
                debugDescription: "unknown upload-rule key '\(unknown.stringValue)'"
            )
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawCommand = try container.decode(String.self, forKey: .command)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawCommand.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .command,
                in: container,
                debugDescription: "upload command must not be blank"
            )
        }
        command = rawCommand

        // Omitted or explicit `null` hostPattern → catch-all. A present-but-blank
        // hostPattern is rejected, not silently treated as a catch-all.
        if container.contains(.hostPattern) {
            if let rawPattern = try container.decodeIfPresent(String.self, forKey: .hostPattern) {
                let trimmed = rawPattern.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .hostPattern,
                        in: container,
                        debugDescription: "hostPattern must not be blank; omit it for a catch-all"
                    )
                }
                hostPattern = trimmed
            } else {
                hostPattern = nil
            }
        } else {
            hostPattern = nil
        }

        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }
}

/// Dynamic key used only to enumerate the actual keys present in a rule object,
/// so unknown keys can be rejected in ``TerminalUploadCommandRule/init(from:)``.
private struct AnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?
    init?(stringValue: String) { self.stringValue = stringValue; intValue = nil }
    init?(intValue: Int) { nil }
}

// MARK: - SettingCodable

/// Stored as a nested JSON object. Decode is all-or-nothing per rule (a malformed
/// rule is rejected and logged), and `Array`'s conformance makes a malformed list
/// reject as a whole, so a typo never silently changes uploads on only some hosts.
extension TerminalUploadCommandRule: SettingCodable {
    public static func decodeFromUserDefaults(_ raw: Any?) -> TerminalUploadCommandRule? {
        decodeFromJSON(raw)
    }

    public func encodeForUserDefaults() -> Any {
        encodeForJSON()
    }

    public static func decodeFromJSON(_ raw: Any?) -> TerminalUploadCommandRule? {
        // Only a JSON object is a valid rule. Guarding on the dictionary shape here
        // also avoids `JSONSerialization`'s uncatchable exception on a non-collection
        // value (a scalar element like ["my-upload …"]), keeping bad config
        // fail-closed instead of fail-crash.
        guard let object = raw as? [String: Any] else {
            if raw != nil, !(raw is NSNull) {
                terminalUploadCommandRuleLogger.error("terminal.uploadCommands: ignoring non-object rule")
            }
            return nil
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: object)
            return try JSONDecoder().decode(TerminalUploadCommandRule.self, from: data)
        } catch {
            terminalUploadCommandRuleLogger.error(
                "terminal.uploadCommands: ignoring invalid rule: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    public func encodeForJSON() -> Any {
        guard let data = try? JSONEncoder().encode(self),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return NSNull()
        }
        return object
    }
}
