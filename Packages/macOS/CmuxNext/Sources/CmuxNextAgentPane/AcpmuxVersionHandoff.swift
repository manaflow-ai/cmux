import Foundation
import os
import Synchronization

/// After an update: hand a running acpmux daemon of another build off to the
/// bundled build (plans/cmux-next/durable-sessions.md section 3). Only a
/// daemon that runs its agents under agent hosts (`_acpmux/status`
/// `agentHosts`) is handed off: its SIGTERM detaches every agent and the new
/// daemon adopts them. An older daemon would end its agents, so it keeps
/// running until it exits on its own.
nonisolated enum AcpmuxVersionHandoff {
    enum Decision: Equatable, Sendable {
        case keep(String)
        case restart
    }

    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "agent-pane.acpmux")
    /// Bundled builds this app process already handed off to: never twice.
    private static let handedOff = Mutex<Set<String>>([])

    /// `acpmux 0.1.0 (<build>)` -> `<build>`.
    static func build(fromVersion version: String) -> String? {
        guard let open = version.firstIndex(of: "("), let close = version.lastIndex(of: ")"), open < close else {
            return nil
        }
        let build = version[version.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
        return build.isEmpty ? nil : build
    }

    static func decide(_ running: String?, _ bundled: String?, _ agentHosts: Bool) -> Decision {
        guard let running else { return .keep("running build unknown") }
        guard let bundled else { return .keep("bundled build unknown") }
        if running == bundled { return .keep("same build") }
        guard agentHosts else { return .keep("its agents would end: no agent hosts") }
        return .restart
    }

    /// The bundled acpmux's build (`<executable> --version`).
    static func bundledBuild(_ environment: AcpmuxEnvironment) async -> String? {
        await Task.detached {
            let process = Process()
            process.executableURL = environment.executable
            process.arguments = ["--version"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return nil }
            // concurrency-allow: a detached task off the main thread; `--version` prints one line and exits
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            // concurrency-allow: same detached task; the process has closed its output
            process.waitUntilExit()
            return build(fromVersion: String(decoding: data, as: UTF8.self))
        }.value
    }

    /// Hands the daemon described by `status` off when it runs another build
    /// and keeps its agents across a restart. Returns true when it stopped
    /// that daemon, so the caller starts the bundled one.
    static func handOffIfStale(_ status: AcpmuxStatus, environment: AcpmuxEnvironment) async -> Bool {
        let bundled = await bundledBuild(environment)
        guard decide(status.build, bundled, status.agentHosts) == .restart, let bundled, let pid = status.pid else {
            return false
        }
        guard handedOff.withLock({ $0.insert(bundled).inserted }) else { return false }
        logger.info("acpmux \(pid) runs build \(status.build ?? "?", privacy: .public); handing off to \(bundled, privacy: .public)")
        do {
            try await AcpmuxStatusClient.shutdown(socketPath: environment.socketPath)
        } catch {
            logger.error("acpmux handoff request failed: \(String(describing: error), privacy: .public)")
            return false
        }
        // The old daemon holds its lock until it exits; the new one needs it.
        return await AgentPaneProcessExit.exitEvent(pid: pid, within: .seconds(15))
    }
}

/// Waits for a process to exit through the kernel's exit event (no polling).
nonisolated enum AgentPaneProcessExit {
    private final class Once: Sendable {
        let done = Mutex(false)
        let deadline = Mutex<Task<Void, Never>?>(nil)
        func first() -> Bool {
            done.withLock { flag in
                defer { flag = true }
                return !flag
            }
        }
    }

    static func exitEvent(pid: Int32, within timeout: Duration) async -> Bool {
        await withCheckedContinuation { continuation in
            let once = Once()
            let queue = DispatchQueue(label: "cmux.next.agent-pane.acpmux-exit.\(pid)")
            nonisolated(unsafe) let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
            let finish: @Sendable (Bool) -> Void = { exited in
                guard once.first() else { return }
                source.cancel()
                once.deadline.withLock { $0?.cancel() }
                continuation.resume(returning: exited)
            }
            // task-owner: the bounded deadline of this one wait; cancelled when the exit arrives
            let timer = Task {
                // wakeup-allow: one bounded deadline per handoff (rare); cancelled at the exit event
                try? await Task.sleep(for: timeout)
                if !Task.isCancelled { finish(false) }
            }
            once.deadline.withLock { $0 = timer }
            source.setEventHandler { finish(true) }
            source.resume()
            if kill(pid, 0) != 0 && errno == ESRCH { finish(true) }
        }
    }
}
