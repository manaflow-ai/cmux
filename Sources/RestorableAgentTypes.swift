import CMUXAgentLaunch
import Foundation

enum RestorableAgentKind: Codable, Hashable, Sendable {
    case claude
    case codex
    case grok
    case pi
    case amp
    case cursor
    case gemini
    case kiro
    case antigravity
    case opencode
    case rovodev
    case hermesAgent
    case copilot
    case codebuddy
    case factory
    case qoder
    case custom(String)

    static let allCases: [RestorableAgentKind] = [
        .claude,
        .codex,
        // Pi and Grok are registry-owned so the built-in Vault registrations can be
        // overridden by project config while direct native values still encode.
        .amp,
        .cursor,
        .gemini,
        .kiro,
        // Antigravity is registry-owned so the built-in Vault registration can be
        // overridden by project config while direct .antigravity values still encode.
        .opencode,
        .rovodev,
        .hermesAgent,
        .copilot,
        .codebuddy,
        .factory,
        .qoder,
    ]

    init?(rawValue: String) {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        switch value {
        case "claude": self = .claude
        case "codex": self = .codex
        case "grok": self = .grok
        case "pi": self = .pi
        case "amp": self = .amp
        case "cursor": self = .cursor
        case "gemini": self = .gemini
        case "kiro": self = .kiro
        case "antigravity": self = .antigravity
        case "opencode": self = .opencode
        case "rovodev": self = .rovodev
        case "hermes-agent": self = .hermesAgent
        case "copilot": self = .copilot
        case "codebuddy": self = .codebuddy
        case "factory": self = .factory
        case "qoder": self = .qoder
        default:
            guard CmuxVaultAgentRegistration.isValidID(value) else { return nil }
            self = .custom(value)
        }
    }

    var rawValue: String {
        switch self {
        case .claude: return "claude"
        case .codex: return "codex"
        case .grok: return "grok"
        case .pi: return "pi"
        case .amp: return "amp"
        case .cursor: return "cursor"
        case .gemini: return "gemini"
        case .kiro: return "kiro"
        case .antigravity: return "antigravity"
        case .opencode: return "opencode"
        case .rovodev: return "rovodev"
        case .hermesAgent: return "hermes-agent"
        case .copilot: return "copilot"
        case .codebuddy: return "codebuddy"
        case .factory: return "factory"
        case .qoder: return "qoder"
        case .custom(let id): return id
        }
    }

    var customAgentID: String? {
        if case .custom(let id) = self {
            return id
        }
        return nil
    }

    var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .grok: return "Grok"
        case .pi: return "Pi"
        case .amp: return "Amp"
        case .cursor: return "Cursor"
        case .gemini: return "Gemini"
        case .kiro: return "Kiro"
        case .antigravity: return "Antigravity"
        case .opencode: return "OpenCode"
        case .rovodev: return "Rovo Dev"
        case .hermesAgent: return "Hermes Agent"
        case .copilot: return "Copilot"
        case .codebuddy: return "CodeBuddy"
        case .factory: return "Factory"
        case .qoder: return "Qoder"
        case .custom(let id): return id
        }
    }

    /// How an agent's session store is keyed, which decides whether `<agent> --resume <id>` is
    /// sensitive to the directory it is launched from. Derived from the shared
    /// ``AgentResumeWorkingDirectory/cwdNamespacing(forKind:)`` so the app and the standalone CLI
    /// apply one classification.
    var cwdNamespacing: AgentCwdNamespacing {
        AgentResumeWorkingDirectory().cwdNamespacing(forKind: rawValue)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let kind = RestorableAgentKind(rawValue: value) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid restorable agent kind '\(value)'"
                )
            )
        }
        self = kind
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    private var hookStoreFilename: String {
        "\(rawValue)-hook-sessions.json"
    }

    func resumeCommand(
        sessionId: String,
        launchCommand: AgentLaunchCommandSnapshot?,
        workingDirectory: String?
    ) -> String? {
        AgentResumeCommandBuilder.resumeShellCommand(
            kind: self,
            sessionId: sessionId,
            launchCommand: launchCommand,
            workingDirectory: workingDirectory
        )
    }

    func hookStoreFileURL(
        homeDirectory: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        applicationSupportDirectory: URL? = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        fileManager: FileManager = .default
    ) -> URL {
        Self.hookStoreReaderLocation(
            homeDirectory: homeDirectory,
            environment: environment,
            applicationSupportDirectory: applicationSupportDirectory,
            bundleIdentifier: bundleIdentifier,
            fileManager: fileManager
        ).directoryURL.appendingPathComponent(hookStoreFilename, isDirectory: false)
    }

    func hookStoreData(
        homeDirectory: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        applicationSupportDirectory: URL? = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        fileManager: FileManager = .default
    ) -> Data? {
        Self.hookStoreReaderLocation(
            homeDirectory: homeDirectory,
            environment: environment,
            applicationSupportDirectory: applicationSupportDirectory,
            bundleIdentifier: bundleIdentifier,
            fileManager: fileManager
        ).storeData(named: hookStoreFilename, fileManager: fileManager)
    }

    static func migrateLegacyHookStoresIfNeeded(
        homeDirectory: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        applicationSupportDirectory: URL? = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        fileManager: FileManager = .default
    ) {
        hookStoreReaderLocation(
            homeDirectory: homeDirectory,
            environment: environment,
            applicationSupportDirectory: applicationSupportDirectory,
            bundleIdentifier: bundleIdentifier,
            fileManager: fileManager
        ).migrateLegacyStoresIfNeeded(fileManager: fileManager)
    }

    private static func hookStoreReaderLocation(
        homeDirectory: String?,
        environment: [String: String],
        applicationSupportDirectory: URL?,
        bundleIdentifier: String?,
        fileManager: FileManager
    ) -> AgentHookStateReaderLocation {
        let legacyHomeDirectory = URL(
            fileURLWithPath: homeDirectory ?? NSHomeDirectory(),
            isDirectory: true
        )
        let usesCurrentUserHome = homeDirectory == nil
            || legacyHomeDirectory.standardizedFileURL
                == fileManager.homeDirectoryForCurrentUser.standardizedFileURL
        return AgentHookStateReaderLocation(
            environment: environment,
            applicationSupportDirectory: usesCurrentUserHome ? applicationSupportDirectory : nil,
            bundleIdentifier: usesCurrentUserHome ? bundleIdentifier : nil,
            legacyHomeDirectory: legacyHomeDirectory,
            fileManager: fileManager
        )
    }
}

struct AgentLaunchCommandSnapshot: Codable, Equatable, Sendable {
    var launcher: String?
    var executablePath: String?
    var arguments: [String]
    var workingDirectory: String?
    var environment: [String: String]?
    var capturedAt: TimeInterval?
    var source: String?
}
