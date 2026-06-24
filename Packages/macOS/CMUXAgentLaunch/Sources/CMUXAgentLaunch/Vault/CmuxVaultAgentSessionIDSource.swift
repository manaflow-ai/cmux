public import Foundation

/// Where a Vault agent's resumable session identifier comes from when a running
/// process is detected.
///
/// `argvOption` reads the value following a named option in the process argv
/// (e.g. `--conversation <id>`); `piSessionFile` and `grokSessionDirectory`
/// locate the identifier from the agent's on-disk session layout. The custom
/// Codable spelling accepts both a single-string shorthand and a tagged object,
/// plus the hyphenated legacy aliases, so config and wire payloads stay
/// byte-compatible.
public enum CmuxVaultAgentSessionIDSource: Codable, Hashable, Sendable {
    /// Read the identifier from the argv value following the given option name.
    case argvOption(String)
    /// Resolve the identifier from a `pi`-compatible agent's session file layout.
    case piSessionFile
    /// Resolve the identifier from a `grok` agent's session directory layout.
    case grokSessionDirectory

    private enum CodingKeys: String, CodingKey {
        case type, argvOption
    }

    /// Decodes from either a single-string shorthand (an option name, or one of
    /// the named-source aliases) or a tagged `{ "type": ..., "argvOption": ... }`
    /// object.
    public init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer(),
           let value = try? container.decode(String.self) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            switch trimmed {
            case "piSessionFile", "pi-session-file":
                self = .piSessionFile
            case "grokSessionDirectory", "grok-session-directory":
                self = .grokSessionDirectory
            default:
                guard !trimmed.isEmpty else {
                    throw DecodingError.dataCorrupted(
                        DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "sessionIdSource must not be blank")
                    )
                }
                self = .argvOption(trimmed)
            }
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type).trimmingCharacters(in: .whitespacesAndNewlines)
        switch type {
        case "piSessionFile", "pi-session-file":
            if let option = try container.decodeIfPresent(String.self, forKey: .argvOption)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !option.isEmpty {
                throw DecodingError.dataCorruptedError(
                    forKey: .argvOption,
                    in: container,
                    debugDescription: "piSessionFile must not include argvOption"
                )
            }
            self = .piSessionFile
        case "grokSessionDirectory", "grok-session-directory":
            if let option = try container.decodeIfPresent(String.self, forKey: .argvOption)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !option.isEmpty {
                throw DecodingError.dataCorruptedError(
                    forKey: .argvOption,
                    in: container,
                    debugDescription: "grokSessionDirectory must not include argvOption"
                )
            }
            self = .grokSessionDirectory
        case "argvOption", "argv-option":
            let option = try container.decodeIfPresent(String.self, forKey: .argvOption)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let option, !option.isEmpty else {
                throw DecodingError.dataCorruptedError(
                    forKey: .argvOption,
                    in: container,
                    debugDescription: "argvOption must not be blank"
                )
            }
            self = .argvOption(option)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown sessionIdSource type '\(type)'"
            )
        }
    }

    /// Encodes as a tagged object so every case round-trips losslessly.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .argvOption(let option):
            try container.encode("argvOption", forKey: .type)
            try container.encode(option, forKey: .argvOption)
        case .piSessionFile:
            try container.encode("piSessionFile", forKey: .type)
        case .grokSessionDirectory:
            try container.encode("grokSessionDirectory", forKey: .type)
        }
    }
}
