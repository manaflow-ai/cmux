import CmuxCloudTui
import CmuxSurfaceCatalogModel
import Foundation

extension CmuxTuiSurfaceProvider {
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
                arguments: CloudTuiRequests.processInfoArguments(
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
            arguments: CloudTuiRequests.processWaitArguments(socketPath: connected.socketPath, terminalID: terminalID, timeoutMs: effectiveMs),
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
            arguments: CloudTuiRequests.outputReadArguments(socketPath: connected.socketPath, terminalID: terminalID, after: after, maxBytes: maxBytes)
        )
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}

extension CmuxTuiSurfaceProvider {
    /// `readScreen`, except that a terminal whose process already exited answers
    /// with its final screen and exit receipt instead of the screen read's error.
    /// The daemon stops resolving an exited terminal's screen once its tab is
    /// gone, but keeps the exit receipt (`terminal.wait_exit`) and the exit
    /// snapshot (`terminal.output` from offset 0), which together are the
    /// answer a caller wanted: what it printed last and how it ended.
    func readScreenReportingExit(terminalID: String) async throws -> [String: Any] {
        do {
            return try await readScreen(terminalID: terminalID)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let readError = error
            // A 1 ms wait answers at once: `exited` with the receipt, or `pending`.
            guard let receipt = try? await waitForExit(terminalID: terminalID, timeoutMs: 1),
                  let exited = CloudTerminalExitedScreenResponse.exitReceipt(receipt) else {
                throw readError
            }
            let output = try? await readOutput(terminalID: terminalID, after: nil, maxBytes: nil)
            return CloudTerminalExitedScreenResponse.response(exit: exited, output: output)
        }
    }
}

/// The `vm.terminal_read` answer for a terminal whose process exited: the same
/// `text` field a live read returns (the final screen), plus `exited: true`,
/// `exit_code` (nil for a signal or unknown outcome), `outcome` and a
/// human `message`. Callers that read only `text` keep working.
enum CloudTerminalExitedScreenResponse {
    /// The exit outcome when `receipt` (a `terminal.wait_exit` answer, possibly
    /// wrapped in `value`) says the process exited; nil while it is pending.
    static func exitReceipt(_ receipt: [String: Any]) -> SurfaceTerminalExit? {
        let body = (receipt["value"] as? [String: Any]) ?? receipt
        guard (body["state"] as? String) == "exited" else { return nil }
        return SurfaceTerminalExit(receipt: body)
    }

    static func response(exit: SurfaceTerminalExit, output: [String: Any]?) -> [String: Any] {
        let body = output.map { ($0["value"] as? [String: Any]) ?? $0 }
        let text = (body?["text"] as? String) ?? ""
        var result: [String: Any] = [
            "text": text,
            "exited": true,
            "message": message(exit),
        ]
        var outcome: [String: Any] = ["kind": exit.kind.rawValue]
        if let code = exit.code { outcome["code"] = code }
        if let signal = exit.signal { outcome["signal"] = signal }
        if let reason = exit.reason { outcome["reason"] = reason }
        result["outcome"] = outcome
        if exit.kind == .exit, let code = exit.code {
            result["exit_code"] = code
        } else {
            result["exit_code"] = NSNull()
        }
        if let exitedAt = exit.exitedAtMilliseconds { result["exited_at"] = String(exitedAt) }
        return result
    }

    /// Plain, non-localized: socket and CLI output is a machine contract.
    static func message(_ exit: SurfaceTerminalExit) -> String {
        switch exit.kind {
        case .exit: return "process exited (code \(exit.code.map(String.init) ?? "unknown"))"
        case .signal: return "process ended by signal \(exit.signal.map(String.init) ?? "unknown")"
        case .unknown: return "process ended (\(exit.reason ?? "unknown outcome"))"
        }
    }
}
