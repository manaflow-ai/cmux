import Foundation

extension CmuxTuiSurfaceProvider {
    /// Type text into a remote terminal without adding a newline.
    func sendText(terminalID: String, text: String) async throws {
        let connected = try await links.connected(machineID: machineID)
        guard let link = await links.link(machineID: machineID) else { throw ProviderError.machineAsleep(machineID) }
        _ = try await link.run(arguments: CloudTuiCommandLine.writeArguments(socketPath: connected.socketPath, terminalID: terminalID, text: text))
    }

    /// Press named keys in the remote terminal, in order.
    func sendKeys(terminalID: String, keys: [String]) async throws {
        let connected = try await links.connected(machineID: machineID)
        guard let link = await links.link(machineID: machineID) else { throw ProviderError.machineAsleep(machineID) }
        _ = try await link.run(arguments: CloudTuiCommandLine.keysArguments(socketPath: connected.socketPath, terminalID: terminalID, keys: keys))
    }

    /// Read the visible terminal grid reported by the daemon.
    func readScreen(terminalID: String) async throws -> [String: Any] {
        let connected = try await links.connected(machineID: machineID)
        guard let link = await links.link(machineID: machineID) else { throw ProviderError.machineAsleep(machineID) }
        let data = try await link.run(arguments: CloudTuiCommandLine.screenReadArguments(socketPath: connected.socketPath, terminalID: terminalID))
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// Wait for the screen pattern, with time for the link to return its result.
    func waitForScreen(terminalID: String, pattern: String, timeoutMs: Int?) async throws -> [String: Any] {
        let connected = try await links.connected(machineID: machineID)
        guard let link = await links.link(machineID: machineID) else { throw ProviderError.machineAsleep(machineID) }
        let effectiveMs = Self.clampedWaitTimeoutMs(timeoutMs)
        let data = try await link.run(
            arguments: CloudTuiCommandLine.screenWaitArguments(socketPath: connected.socketPath, terminalID: terminalID, pattern: pattern, timeoutMs: effectiveMs),
            timeout: .milliseconds(effectiveMs + 5_000)
        )
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    nonisolated static let defaultWaitTimeoutMs = 30_000
    nonisolated static let maxWaitTimeoutMs = 3_600_000

    nonisolated static func clampedWaitTimeoutMs(_ requested: Int?) -> Int {
        guard let requested, requested > 0 else { return defaultWaitTimeoutMs }
        return min(requested, maxWaitTimeoutMs)
    }
}

/// Two more headless terminal primitives over the machine's link, beside `readScreen`
/// and `waitForScreen`: the process's EXIT (a fact the daemon records) and its retained
/// OUTPUT (the whole log, not the visible rows). Together they turn "run this to
/// completion and give me the result" into `wait-exit` + `output` instead of a prompt
/// regex and a screenful of text.
extension CmuxTuiSurfaceProvider {
    /// Returns the cwd of the process group currently owning the remote PTY.
    /// This is deliberately a live process query: the snapshot's `cwd` is the
    /// terminal's spawn directory and remains stale after a remote `cd`.
    func currentWorkingDirectory(of resource: SurfaceResource) async -> String? {
        guard resource.kind == .terminal else { return nil }
        do {
            let connected = try await links.connected(machineID: machineID)
            guard let link = await links.link(machineID: machineID) else { return nil }
            let data = try await link.run(
                arguments: CloudTuiCommandLine.processInfoArguments(
                    socketPath: connected.socketPath,
                    terminalID: resource.id.key
                )
            )
            guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            return CloudTuiCommandLine.foregroundWorkingDirectory(fromProcessInfo: result)
        } catch {
            // Directory inheritance is best effort. A daemon without the process
            // query capability must retain the existing workspace fallback.
            return nil
        }
    }

    /// Block until the remote terminal's process exits or `timeoutMs` elapses (the same
    /// clamp as `waitForScreen`: nil/non-positive → 30 s, at most an hour). The daemon's
    /// answer: `{state: "exited", terminal_id, lifecycle, outcome: {kind: exit, code} |
    /// {kind: signal, signal, core_dumped} | {kind: unknown, reason}, exited_at}` or
    /// `{state: "pending", terminal_id, lifecycle, …}`.
    func waitForExit(terminalID: String, timeoutMs: Int?) async throws -> [String: Any] {
        let connected = try await links.connected(machineID: machineID)
        guard let link = await links.link(machineID: machineID) else { throw ProviderError.machineAsleep(machineID) }
        let effectiveMs = Self.clampedWaitTimeoutMs(timeoutMs)
        let linkTimeout = Duration.milliseconds(effectiveMs + 5_000)
        let data = try await link.run(
            arguments: CloudTuiCommandLine.processWaitArguments(socketPath: connected.socketPath, terminalID: terminalID, timeoutMs: effectiveMs),
            timeout: linkTimeout
        )
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// The remote terminal's retained output from `after` (a `next_offset` the daemon
    /// handed back earlier; nil = the earliest byte still kept), at most `maxBytes` of raw
    /// stream per call (nil = the daemon's 256 KiB window): `{text, start_offset,
    /// next_offset, complete}`. `complete == false` means "call again with next_offset".
    func readOutput(terminalID: String, after: Int?, maxBytes: Int?) async throws -> [String: Any] {
        let connected = try await links.connected(machineID: machineID)
        guard let link = await links.link(machineID: machineID) else { throw ProviderError.machineAsleep(machineID) }
        let data = try await link.run(
            arguments: CloudTuiCommandLine.outputReadArguments(socketPath: connected.socketPath, terminalID: terminalID, after: after, maxBytes: maxBytes)
        )
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}
