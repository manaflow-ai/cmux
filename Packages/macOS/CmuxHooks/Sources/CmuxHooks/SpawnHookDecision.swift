import Foundation

/// The decision returned by a pre-spawn hook.
public enum SpawnHookDecision: Sendable, Equatable, Decodable {
    /// Allow the spawn unchanged.
    case allow

    /// Rewrite selected spawn inputs.
    case rewrite(command: String??, workingDirectory: String?, environment: [String: String])

    /// Deny the spawn.
    case deny(reason: String)

    /// Creates a decision from hook stdout JSON.
    /// - Parameter decoder: The decoder containing the hook decision object.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decision = try container.decode(String.self, forKey: .decision)
        switch decision {
        case "allow":
            self = .allow
        case "rewrite":
            let command: String??
            if container.contains(.command) {
                command = try container.decodeNil(forKey: .command)
                    ? .some(nil)
                    : .some(try container.decode(String.self, forKey: .command))
            } else {
                command = nil
            }
            let workingDirectory = try container.decodeIfPresent(String.self, forKey: .workingDirectory)
            let environment = try container.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
            self = .rewrite(command: command, workingDirectory: workingDirectory, environment: environment)
        case "deny":
            let reason = try container.decodeIfPresent(String.self, forKey: .reason)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            self = .deny(reason: reason?.isEmpty == false ? reason! : "denied by pre-spawn hook")
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .decision,
                in: container,
                debugDescription: "Unsupported pre-spawn hook decision"
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case decision
        case command
        case workingDirectory
        case env
        case reason
    }
}
