import Foundation

/// Two more headless terminal primitives over the machine's link, beside `readScreen`
/// and `waitForScreen`: the process's EXIT (a fact the daemon records) and its retained
/// OUTPUT (the whole log, not the visible rows). Together they turn "run this to
/// completion and give me the result" into `wait-exit` + `output` instead of a prompt
/// regex and a screenful of text.
extension CmuxTuiSurfaceProvider {
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
