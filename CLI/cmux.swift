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

struct CLIError: Error, CustomStringConvertible {
    let message: String
    let exitCode: Int32

    init(message: String, exitCode: Int32 = 1) {
        self.message = message
        self.exitCode = exitCode
    }

    var description: String { message }
}

enum CLISocketEnvironment {
    static func socketPath(in environment: [String: String]) throws -> String? {
        let socketPath = normalized(environment["CMUX_SOCKET_PATH"])
        let legacySocketPath = normalized(environment["CMUX_SOCKET"])
        if let socketPath, let legacySocketPath, socketPath != legacySocketPath {
            throw CLIError(message: "Refusing to choose socket: CMUX_SOCKET_PATH and CMUX_SOCKET differ. Use CMUX_SOCKET_PATH or unset CMUX_SOCKET.")
        }
        return socketPath ?? legacySocketPath
    }

    static func socketPathForTelemetry(in environment: [String: String]) -> String? {
        normalized(environment["CMUX_SOCKET_PATH"]) ?? normalized(environment["CMUX_SOCKET"])
    }

    private static func normalized(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct WindowInfo {
    let index: Int
    let id: String
    let key: Bool
    let selectedWorkspaceId: String?
    let workspaceCount: Int
}

struct NotificationInfo {
    let id: String
    let workspaceId: String
    let surfaceId: String?
    let isRead: Bool
    let title: String
    let subtitle: String
    let body: String
    let createdAt: String?
    let tabTitle: String?
}

let agentHookWrapperProcessNames: Set<String> = [
    "sh",
    "bash",
    "zsh",
    "env"
]

enum HookAgentProcessKind {
    case codex
    case claude
}

let suppressSubagentNotificationsDefaultsKey = "suppressSubagentNotifications"
let suppressSubagentNotificationsEnvironmentKey = "CMUX_SUPPRESS_SUBAGENT_NOTIFICATIONS"
let managedSubagentEnvironmentKey = "CMUX_AGENT_MANAGED_SUBAGENT"
let codexTeamsThreadEnvironmentKey = "CMUX_CODEX_TEAMS_THREAD_ID"
let codexTeamsParentThreadEnvironmentKey = "CMUX_CODEX_TEAMS_PARENT_THREAD_ID"
let codexTeamsDepthEnvironmentKey = "CMUX_CODEX_TEAMS_DEPTH"

enum CLIIDFormat: String {
    case refs
    case uuids
    case both

    static func parse(_ raw: String?) throws -> CLIIDFormat? {
        guard let raw else { return nil }
        guard let parsed = CLIIDFormat(rawValue: raw.lowercased()) else {
            throw CLIError(message: "--id-format must be one of: refs, uuids, both")
        }
        return parsed
    }
}

enum TopSortKey: Equatable {
    case cpu
    case memory
    case proc
}

enum TopTextFormat: Equatable {
    case tree
    case tsv
}

struct CMUXCLI {
    let args: [String]

    func captureSocketTransportError(telemetry: CLISocketSentryTelemetry, stage: String, error: Error, client: SocketClient) {
        if client.hasUnfinishedOperationTelemetry() {
            telemetry.captureError(stage: stage, error: error, data: client.operationTelemetryContext())
        }
    }

    func jsonString(_ object: Any) -> String {
        var options: JSONSerialization.WritingOptions = [.prettyPrinted]
        options.insert(.sortedKeys)
        options.insert(.withoutEscapingSlashes)
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: options),
              let output = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return output
    }

}

private enum CMUXCLIOutput {
    static func writeStandardError(_ message: String) {
        write(Data(message.utf8), to: STDERR_FILENO)
    }

    private static func write(_ data: Data, to fd: Int32) {
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                return
            }

            var offset = 0
            while offset < data.count {
                let bytesWritten = Darwin.write(fd, baseAddress.advanced(by: offset), data.count - offset)
                if bytesWritten > 0 {
                    offset += bytesWritten
                } else if bytesWritten == -1, errno == EINTR {
                    continue
                } else {
                    return
                }
            }
        }
    }
}

@main
struct CMUXTermMain {
    static func main() {
        // CLI tools should ignore SIGPIPE so closed stdout pipes do not terminate the process.
        _ = signal(SIGPIPE, SIG_IGN)
        let cli = CMUXCLI(args: CommandLine.arguments)
        do {
            try cli.run()
        } catch {
            CMUXCLIOutput.writeStandardError("Error: \(error)\n")
            let exitCode = (error as? CLIError)?.exitCode ?? 1
            exit(exitCode)
        }
    }
}
