import Foundation
import CMUXAgentLaunch
import CmuxFoundation
import CmuxSocketControl
import CoreFoundation
import CryptoKit
import Darwin
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif
#if canImport(Security)
import Security
#endif
#if canImport(Sentry)
import Sentry
#endif


// MARK: - Agent hook record models
struct ClaudeHookParsedInput {
    let rawObject: [String: Any]?
    let object: [String: Any]?
    let rawFallback: String?
    let sessionId: String?
    let turnId: String?
    let cwd: String?
    let transcriptPath: String?
}

enum AgentHookNotificationStatus: String, Codable {
    case idle
    case needsInput
    case error
}

enum AgentHookRuntimeStatus: String, Codable {
    case running
    case idle
    case needsInput
    case error
}

struct AgentHookNotificationSummary {
    let subtitle: String
    let body: String
    let status: AgentHookNotificationStatus?
    let isFallback: Bool
}

#if DEBUG
func agentHookDebugLog(
    _ message: @autoclosure () -> String,
    socketPath: String? = nil,
    env: [String: String] = ProcessInfo.processInfo.environment
) {
    let logPath = agentHookDebugLogPath(socketPath: socketPath, env: env)
    let timestamp = String(format: "%.3f", Date().timeIntervalSince1970)
    let line = "\(timestamp) \(message())\n"
    guard let data = line.data(using: .utf8) else { return }

    if let handle = FileHandle(forWritingAtPath: logPath) {
        defer { try? handle.close() }
        guard (try? handle.seekToEnd()) != nil else { return }
        try? handle.write(contentsOf: data)
    } else {
        FileManager.default.createFile(atPath: logPath, contents: data)
    }
}

private func agentHookDebugLogPath(socketPath: String?, env: [String: String]) -> String {
    if let explicit = agentHookDebugNonEmpty(env["CMUX_DEBUG_LOG"]) {
        return NSString(string: explicit).expandingTildeInPath
    }

    if let socketPath {
        let socketName = URL(fileURLWithPath: socketPath).lastPathComponent
        if socketName.hasPrefix("cmux-debug-"), socketName.hasSuffix(".sock") {
            let logName = String(socketName.dropLast(".sock".count)) + ".log"
            return URL(fileURLWithPath: "/tmp", isDirectory: true)
                .appendingPathComponent(logName, isDirectory: false)
                .path
        }
    }

    if let lastPath = try? String(contentsOfFile: "/tmp/cmux-last-debug-log-path", encoding: .utf8),
       let normalized = agentHookDebugNonEmpty(lastPath) {
        return NSString(string: normalized).expandingTildeInPath
    }

    return "/tmp/cmux-debug.log"
}

private func agentHookDebugNonEmpty(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
          !trimmed.isEmpty else {
        return nil
    }
    return trimmed
}

func agentHookDebugShort(_ value: String?) -> String {
    guard let value = agentHookDebugNonEmpty(value) else { return "nil" }
    return String(value.prefix(12))
}

func agentHookDebugSocketName(_ socketPath: String?) -> String {
    guard let socketPath = agentHookDebugNonEmpty(socketPath) else { return "nil" }
    return URL(fileURLWithPath: socketPath).lastPathComponent
}
#endif

struct ClaudeHookSessionRecord: Codable {
    var sessionId: String
    var workspaceId: String
    var surfaceId: String
    var cwd: String?
    var transcriptPath: String?
    var pid: Int?
    var launchCommand: AgentHookLaunchCommandRecord?
    var isRestorable: Bool?
    var agentLifecycle: AgentHibernationLifecycleState?
    var lastSubtitle: String?
    var lastBody: String?
    var lastNotificationStatus: AgentHookNotificationStatus?
    var lastEmittedNotificationFingerprint: String?
    var lastEmittedNotificationAt: TimeInterval?
    var runtimeStatus: AgentHookRuntimeStatus?
    var activePromptDepth: Int?
    var activePromptTurnId: String?
    var activePromptTurnIds: [String]?
    var lastPromptTurnId: String?
    var terminalPromptTurnIds: [String]?
    var startedAt: TimeInterval
    var updatedAt: TimeInterval
}

struct ClaudeHookActiveSessionRecord: Codable {
    var sessionId: String
    var turnId: String?
    var allowsNewSessionReplacement: Bool?
    var updatedAt: TimeInterval
}

struct AgentHookLaunchCommandRecord: Codable {
    var launcher: String?
    var executablePath: String?
    var arguments: [String]
    var workingDirectory: String?
    var environment: [String: String]?
    var capturedAt: TimeInterval?
    var source: String?
}

struct CodexMonitorLeaseRecord: Codable {
    var leaseId: String
    var sessionId: String
    var turnId: String?
    var workspaceId: String
    var surfaceId: String?
    var createdAt: TimeInterval
    var retiredAt: TimeInterval?
}

struct ClaudeHookSessionStoreFile: Codable {
    var version: Int = 1
    var sessions: [String: ClaudeHookSessionRecord] = [:]
    var activeSessionsByWorkspace: [String: ClaudeHookActiveSessionRecord] = [:]

    enum CodingKeys: String, CodingKey {
        case version
        case sessions
        case activeSessionsByWorkspace
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        sessions = try container.decodeIfPresent([String: ClaudeHookSessionRecord].self, forKey: .sessions) ?? [:]
        activeSessionsByWorkspace = try container.decodeIfPresent(
            [String: ClaudeHookActiveSessionRecord].self,
            forKey: .activeSessionsByWorkspace
        ) ?? [:]
    }
}

