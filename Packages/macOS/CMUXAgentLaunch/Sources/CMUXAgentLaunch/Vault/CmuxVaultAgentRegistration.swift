public import Foundation

/// A single Vault agent definition: how to detect a running instance, where its
/// resumable session identifier comes from, and the command templates used to
/// resume or fork a session.
///
/// Values are validated on decode (`id` must match `[A-Za-z0-9._-]+` and not
/// collide with a reserved built-in agent id; `name` and `resumeCommand` must be
/// non-blank; command templates must reference `{{sessionId}}` or
/// `{{sessionPath}}`). Coding keys and validation match the legacy app type
/// byte-for-byte so persisted config and wire payloads stay compatible.
public struct CmuxVaultAgentRegistration: Codable, Hashable, Sendable {
    /// Stable identifier for the agent (also the config key).
    public var id: String
    /// Human-readable display name.
    public var name: String
    /// Optional asset catalog name for the agent's icon.
    public var iconAssetName: String?
    /// How to recognize a running instance of this agent.
    public var detect: CmuxVaultAgentDetectRule
    /// Where the resumable session identifier comes from.
    public var sessionIdSource: CmuxVaultAgentSessionIDSource
    /// Command template used to resume a session.
    public var resumeCommand: String
    /// Optional template for forking (branching) a session into a new copy,
    /// e.g. "{{executable}} --session {{sessionId}} --fork". Same placeholders as
    /// `resumeCommand`. When nil, the agent has no fork capability and Fork
    /// Conversation stays hidden for it (resume still works via `resumeCommand`).
    public var forkCommand: String?
    /// How a resumed session treats the recorded working directory.
    public var cwd: CmuxVaultAgentCWDPolicy
    /// Optional directory where the agent stores its sessions.
    public var sessionDirectory: String?

    private enum CodingKeys: String, CodingKey {
        case id, name, iconAssetName, detect, sessionIdSource, resumeCommand, forkCommand, cwd, sessionDirectory
    }

    /// Creates a registration, trimming the icon and fork-command values to nil
    /// when blank.
    public init(
        id: String,
        name: String,
        iconAssetName: String? = nil,
        detect: CmuxVaultAgentDetectRule,
        sessionIdSource: CmuxVaultAgentSessionIDSource,
        resumeCommand: String,
        forkCommand: String? = nil,
        cwd: CmuxVaultAgentCWDPolicy = .preserve,
        sessionDirectory: String? = nil
    ) {
        self.id = id
        self.name = name
        self.iconAssetName = Self.normalizedOptional(iconAssetName)
        self.detect = detect
        self.sessionIdSource = sessionIdSource
        self.resumeCommand = resumeCommand
        self.forkCommand = Self.normalizedOptional(forkCommand)
        self.cwd = cwd
        self.sessionDirectory = sessionDirectory
    }

    /// Decodes and validates a registration, rejecting invalid/reserved ids,
    /// blank names, and command templates missing the required placeholders.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(String.self, forKey: .id).trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidID(id),
              !Self.isReservedID(id) else {
            throw DecodingError.dataCorruptedError(
                forKey: .id,
                in: container,
                debugDescription: "Vault agent id must contain only letters, numbers, dots, underscores, and hyphens"
            )
        }

        let name = try container.decode(String.self, forKey: .name).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .name,
                in: container,
                debugDescription: "Vault agent name must not be blank"
            )
        }

        let resumeCommand = try container.decode(String.self, forKey: .resumeCommand)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resumeCommand.isEmpty,
              resumeCommand.contains("{{sessionId}}") || resumeCommand.contains("{{sessionPath}}") else {
            throw DecodingError.dataCorruptedError(
                forKey: .resumeCommand,
                in: container,
                debugDescription: "Vault agent resumeCommand must include {{sessionId}} or {{sessionPath}}"
            )
        }

        self.id = id
        self.name = name
        self.iconAssetName = Self.normalizedOptional(try container.decodeIfPresent(String.self, forKey: .iconAssetName))
        self.detect = try container.decodeIfPresent(CmuxVaultAgentDetectRule.self, forKey: .detect) ?? .init()
        self.sessionIdSource = try container.decode(CmuxVaultAgentSessionIDSource.self, forKey: .sessionIdSource)
        self.resumeCommand = resumeCommand
        if let forkCommand = try container.decodeIfPresent(String.self, forKey: .forkCommand)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !forkCommand.isEmpty {
            guard forkCommand.contains("{{sessionId}}") || forkCommand.contains("{{sessionPath}}") else {
                throw DecodingError.dataCorruptedError(
                    forKey: .forkCommand,
                    in: container,
                    debugDescription: "Vault agent forkCommand must include {{sessionId}} or {{sessionPath}}"
                )
            }
            self.forkCommand = forkCommand
        } else {
            self.forkCommand = nil
        }
        self.cwd = try container.decodeIfPresent(CmuxVaultAgentCWDPolicy.self, forKey: .cwd) ?? .preserve
        let directory = try container.decodeIfPresent(String.self, forKey: .sessionDirectory)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.sessionDirectory = directory?.isEmpty == true ? nil : directory
    }

    /// Whether the given string is a syntactically valid agent id.
    public static func isValidID(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        return value.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil
    }

    private static func normalizedOptional(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    /// The raw values of the app-side `RestorableAgentKind.allCases` cases that a
    /// project config may NOT redefine via a Vault registration.
    ///
    /// Mirrored here as string literals so the package stays decoupled from the
    /// app `RestorableAgentKind` enum (which deliberately does not live in this
    /// package). Registry-owned kinds (`grok`, `pi`, `antigravity`) are absent on
    /// purpose: their built-in Vault registrations can be overridden by project
    /// config while their native values still encode, exactly as the app enum's
    /// `allCases` omits them.
    private static let reservedBuiltInIDs: Set<String> = [
        "claude",
        "codex",
        "amp",
        "cursor",
        "gemini",
        "kiro",
        "opencode",
        "rovodev",
        "hermes-agent",
        "copilot",
        "codebuddy",
        "factory",
        "qoder",
    ]

    private static func isReservedID(_ value: String) -> Bool {
        reservedBuiltInIDs.contains(value)
    }

    /// The executable name to substitute for `{{executable}}` when no explicit
    /// override is supplied: the first non-blank detect process name, else `id`.
    public var defaultExecutable: String {
        if let processName = detect.processName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !processName.isEmpty {
            return processName
        }
        if let processName = detect.processNames.first?.trimmingCharacters(in: .whitespacesAndNewlines),
           !processName.isEmpty {
            return processName
        }
        return id
    }

    /// Built-in registration for the `pi` agent.
    public static var builtInPi: CmuxVaultAgentRegistration {
        CmuxVaultAgentRegistration(
            id: "pi",
            name: "Pi",
            iconAssetName: "AgentIcons/Pi",
            detect: CmuxVaultAgentDetectRule(processName: "pi", argvContains: ["pi"]),
            sessionIdSource: .piSessionFile,
            resumeCommand: "{{executable}} --session {{sessionId}}",
            forkCommand: "{{executable}} --session {{sessionId}} --fork",
            cwd: .preserve,
            sessionDirectory: "~/.pi/agent/sessions"
        )
    }

    /// Built-in registration for the `omp` agent.
    public static var builtInOmp: CmuxVaultAgentRegistration {
        CmuxVaultAgentRegistration(
            id: "omp",
            name: "OMP",
            detect: CmuxVaultAgentDetectRule(
                processName: "omp",
                alternateArgvContains: ["@oh-my-pi/pi-coding-agent"]
            ),
            sessionIdSource: .piSessionFile,
            resumeCommand: "{{executable}} --session {{sessionId}}",
            forkCommand: "{{executable}} --session {{sessionId}} --fork",
            cwd: .preserve,
            sessionDirectory: "~/.omp/agent/sessions"
        )
    }

    /// Built-in registration for the `antigravity` agent.
    public static var builtInAntigravity: CmuxVaultAgentRegistration {
        CmuxVaultAgentRegistration(
            id: "antigravity",
            name: "Antigravity",
            iconAssetName: "AgentIcons/Antigravity",
            detect: CmuxVaultAgentDetectRule(processNames: ["agy", "antigravity"]),
            sessionIdSource: .argvOption("--conversation"),
            resumeCommand: "{{executable}} --conversation {{sessionId}}",
            cwd: .preserve,
            sessionDirectory: "~/.gemini/antigravity-cli"
        )
    }

    /// Built-in registration for the `grok` agent.
    public static var builtInGrok: CmuxVaultAgentRegistration {
        CmuxVaultAgentRegistration(
            id: "grok",
            name: "Grok",
            detect: CmuxVaultAgentDetectRule(processNames: ["grok", "grok-macos-aarch64", "grok-macos-aarch"]),
            sessionIdSource: .grokSessionDirectory,
            resumeCommand: "{{executable}} -r {{sessionId}}",
            cwd: .preserve,
            sessionDirectory: "~/.grok/sessions"
        )
    }
}
