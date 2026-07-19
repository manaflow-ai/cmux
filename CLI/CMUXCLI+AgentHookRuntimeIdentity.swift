import Foundation

extension CMUXCLI {
    /// Adds the connected app's runtime identity to direct store queries. A CLI
    /// launched from a normal shell has no inherited `CMUX_RUNTIME_ID`, while a
    /// CLI launched inside a different cmux can inherit the wrong one. An
    /// explicit `--socket` names the authority, so connected evidence wins.
    func agentSessionQueryEnvironment(
        environment: [String: String],
        socketCapabilities: [String: Any]
    ) -> [String: String] {
        guard let identity = AgentCmuxRuntimeIdentity.resolve(
            environment: environment,
            socketCapabilities: socketCapabilities
        ) else {
            return environment
        }
        return identity.applying(to: environment)
    }

    /// Resolves hook-store ownership from the connected cmux process without
    /// touching the UI thread. `system.capabilities` is a socket-worker pure
    /// probe; its one-second bound and environment fallback keep hooks safe for
    /// older or unavailable servers.
    func agentHookStoreEnvironment(
        environment: [String: String],
        client: SocketClient
    ) -> [String: String] {
        let capabilities = (try? client.sendV2(
            method: "system.capabilities",
            responseTimeout: 1
        )) ?? [:]
        return agentSessionQueryEnvironment(
            environment: environment,
            socketCapabilities: capabilities
        )
    }
}

#if DEBUG
extension CMUXCLI {
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
                    .appendingPathComponent(logName, isDirectory: false).path
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
              !trimmed.isEmpty else { return nil }
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
}
#endif
