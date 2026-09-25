import Foundation
import Darwin
import CMUXAgentLaunch

extension CMUXCLI {
    /// Keeps previously installed hook scripts on the same spool transport.
    func admitLegacyCodexToolFeed(command: String, arguments: [String]) async -> Bool {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["CMUX_CODEX_FEED_DIR"], !path.isEmpty else { return false }
        let action: String?
        if command == "hooks", arguments.starts(with: ["enqueue", "codex"]) {
            action = arguments.dropFirst(2).first
        } else if command == "hooks", arguments.first == "codex" {
            action = arguments.dropFirst().first
        } else if (command == "hooks" && arguments.first == "feed") || command == "feed-hook",
                  optionValue(arguments, name: "--source") == "codex" {
            action = optionValue(arguments, name: "--event")
        } else {
            return false
        }
        let event: String
        switch action {
        case "pre-tool-use", "PreToolUse": event = "pre-tool-use"
        case "post-tool-use", "PostToolUse": event = "post-tool-use"
        default: return false
        }
        if env["CMUX_CODEX_HOOKS_DISABLED"] != "1",
           env["CMUX_SURFACE_ID"]?.isEmpty == false,
           let payload = Self.readBoundedFeedHookStdin(maxBytes: 65536) {
            await CodexToolFeedSpool(directory: URL(fileURLWithPath: path))
                .publish(event: event, payload: payload, producerPID: getpid())
        }
        print("{}")
        return true
    }

    /// One wrapper-owned process amortizes CLI startup and socket authentication
    /// across the session. Failed delivery drops bounded telemetry; it never
    /// turns an unavailable app into a retry or per-tool process storm.
    func runCodexToolFeedWorker(
        socketPath: String,
        socketPassword: String?,
        telemetry: CLISocketSentryTelemetry
    ) async {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["CMUX_CODEX_FEED_DIR"], !path.isEmpty,
              let parent = env["CMUX_CODEX_PID"].flatMap(Int32.init), parent > 1 else { return }
        let spool = CodexToolFeedSpool(directory: URL(fileURLWithPath: path))
        let client = SocketClient(path: socketPath)
        // Remote relays retain their existing scoped command path.
        guard !client.isRelayBacked else { await spool.close(); return }
        var retryAfter = Date.distantPast
        var reconnectDelay: TimeInterval = 1
        for await _ in await spool.changes(parentPID: parent) {
            if Task.isCancelled { break }
            let records = await spool.drain()
            guard !records.isEmpty, Date.now >= retryAfter else { continue }
            do {
                if client.socketFD < 0 {
                    try client.connectWithoutRetry(responseTimeout: 0.05)
                    try authenticateClientIfNeeded(
                        client, explicitPassword: socketPassword,
                        socketPath: socketPath, responseTimeout: 0.05
                    )
                }
                for record in records {
                    guard client.socketFD >= 0 else { break }
                    let event = record.event == "pre-tool-use" ? "PreToolUse" : "PostToolUse"
                    try runFeedHook(
                        commandArgs: ["--source", "codex", "--event", event],
                        client: client, socketPath: socketPath,
                        socketPassword: socketPassword, telemetry: telemetry,
                        inputData: record.payload
                    )
                }
            } catch {
                client.close()
            }
            if client.socketFD < 0 {
                reconnectDelay = min(30, reconnectDelay * 2)
                retryAfter = Date.now.addingTimeInterval(reconnectDelay + Double(parent % 100) / 100)
            } else {
                reconnectDelay = 1
            }
        }
        client.close()
        await spool.close()
    }
}
