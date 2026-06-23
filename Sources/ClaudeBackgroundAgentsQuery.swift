import Darwin
import Foundation
import CMUXAgentLaunch

/// Resolves live Claude Code background agents (`claude agents --json`) for the restorable
/// session index so a transcript-less ghost panel can be reconciled to its real session id.
/// https://github.com/manaflow-ai/cmux/issues/6622
///
/// Best-effort and self-contained: any failure yields no agents, so the index degrades to its
/// prior behaviour rather than blocking or surfacing a wrong session. Results are cached per
/// `CLAUDE_CONFIG_DIR` for a short TTL so the event-driven, off-main index reload does not
/// respawn `claude` on every refresh.
///
/// The cache/TTL/coalescing state machine is decoupled from the subprocess: a `probe` and a
/// `now` clock are injected (defaulting to the real `claude agents --json` runner and the
/// system clock) so the caching behaviour is unit-testable without spawning a process.
/// `@unchecked Sendable`: the cache is guarded by a lock and `live(configDir:)` is invoked
/// only from the off-main loaders.
final class ClaudeBackgroundAgentsQuery: @unchecked Sendable {
    static let shared = ClaudeBackgroundAgentsQuery()

    private let probe: @Sendable (String?) -> [ClaudeBackgroundAgentSnapshot]
    private let now: @Sendable () -> Date
    private let cacheTTL: TimeInterval

    private let lock = NSLock()
    // Serializes the probe so a cache miss observed by two concurrent off-main loaders does
    // not spawn `claude agents --json` twice; the post-acquire re-check returns the first
    // fetch's freshly cached result to the second caller.
    private let fetchLock = NSLock()
    private var cache: [String: (agents: [ClaudeBackgroundAgentSnapshot], fetchedAt: Date)] = [:]

    init(
        cacheTTL: TimeInterval = 20,
        now: @escaping @Sendable () -> Date = { Date() },
        probe: @escaping @Sendable (String?) -> [ClaudeBackgroundAgentSnapshot] = claudeBackgroundAgentsProbe
    ) {
        self.cacheTTL = cacheTTL
        self.now = now
        self.probe = probe
    }

    /// Off-main: returns cached agents within the TTL, otherwise runs the bounded probe and
    /// caches the result. Must not be called on the main thread.
    func live(configDir: String?) -> [ClaudeBackgroundAgentSnapshot] {
        let key = configDir ?? ""
        if let fresh = freshCachedAgents(forKey: key) {
            return fresh
        }

        fetchLock.lock()
        defer { fetchLock.unlock() }
        // Re-check under the fetch lock: a concurrent probe for this key may have just filled
        // the cache while we waited.
        if let fresh = freshCachedAgents(forKey: key) {
            return fresh
        }

        let agents = probe(configDir)
        lock.lock()
        cache[key] = (agents, now())
        lock.unlock()
        return agents
    }

    /// Main-thread safe: returns whatever the off-main loaders have already cached for this
    /// config dir, never spawning `claude`. The synchronous session-save path uses this so it
    /// reconciles from the warm cache without a subprocess on the main thread. Applies the same
    /// TTL as ``live(configDir:)`` so a stale entry — where the daemon would now report zero, a
    /// different, or multiple ambiguous agents — degrades to no reconciliation instead of
    /// persisting a wrong session.
    func cachedOnly(configDir: String?) -> [ClaudeBackgroundAgentSnapshot] {
        freshCachedAgents(forKey: configDir ?? "") ?? []
    }

    private func freshCachedAgents(forKey key: String) -> [ClaudeBackgroundAgentSnapshot]? {
        lock.lock()
        defer { lock.unlock() }
        guard let cached = cache[key], now().timeIntervalSince(cached.fetchedAt) < cacheTTL else {
            return nil
        }
        return cached.agents
    }
}

/// Runs `claude agents --json` and parses the live background agents, or returns none on any
/// failure (claude not found, non-zero exit, malformed JSON, or the bounded probe timing out).
/// The default `probe` for ``ClaudeBackgroundAgentsQuery``.
/// https://github.com/manaflow-ai/cmux/issues/6622
let claudeBackgroundAgentsProbe: @Sendable (String?) -> [ClaudeBackgroundAgentSnapshot] = { configDir in
    ClaudeBackgroundAgentsProbeRunner(configDir: configDir).run()
}

/// Bounded `claude agents --json` subprocess runner. An instance owns one probe so the
/// non-`Sendable` `Process`/`FileHandle` stay scoped to a single run.
private struct ClaudeBackgroundAgentsProbeRunner {
    let configDir: String?

    private static let probeTimeout: TimeInterval = 5
    private static let terminateGrace: TimeInterval = 1

    func run() -> [ClaudeBackgroundAgentSnapshot] {
        guard let plan = resolvedClaudeLaunchPlan() else { return [] }

        let process = Process()
        process.executableURL = plan.executableURL
        process.arguments = ["agents", "--json"]
        // Use the resolver's launch environment (which rebuilds PATH to include Homebrew,
        // ~/.local/bin, nvm/mise/asdf, etc.). A Dock-launched macOS app's own PATH is stripped,
        // so running the resolved claude (often a shim that execs `/usr/bin/env node`) under it
        // would exit nonzero and silently no-op the probe.
        var environment = plan.environment
        if let configDir = configDir?.trimmingCharacters(in: .whitespacesAndNewlines),
           !configDir.isEmpty {
            environment["CLAUDE_CONFIG_DIR"] = (configDir as NSString).expandingTildeInPath
        } else {
            // No trusted config: query claude's default root so the daemon queried matches the
            // default/account roots the index validates transcripts against (and the default
            // "" cache key), instead of an ambient CLAUDE_CONFIG_DIR inherited by the app.
            environment.removeValue(forKey: "CLAUDE_CONFIG_DIR")
        }
        process.environment = environment

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        // Signal on real process exit so the exit wait below is bounded too, not just the read.
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            return []
        }

        // Drain stdout on a background queue so the probe stays bounded even if the read would
        // otherwise block: each wait below has a deadline and escalates SIGTERM -> SIGKILL on
        // expiry, which closes stdout and forces the process to exit.
        let box = ProbeBox(process: process, readHandle: stdout.fileHandleForReading)
        let output = DataBox()
        let readDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            output.set(box.readHandle.readDataToEndOfFile())
            readDone.signal()
        }

        func terminateAndDrain() {
            if box.process.isRunning { box.process.terminate() }
            if exited.wait(timeout: .now() + Self.terminateGrace) == .timedOut {
                if box.process.isRunning { kill(box.process.processIdentifier, SIGKILL) }
                _ = exited.wait(timeout: .now() + Self.terminateGrace)
            }
            _ = readDone.wait(timeout: .now() + Self.terminateGrace)
        }

        // Bound the read.
        if readDone.wait(timeout: .now() + Self.probeTimeout) == .timedOut {
            terminateAndDrain()
            return []
        }
        // Bound process exit: stdout can close while the process hangs, so do not call the
        // unbounded `waitUntilExit()` — wait on the termination handler with a deadline.
        if exited.wait(timeout: .now() + Self.terminateGrace) == .timedOut {
            terminateAndDrain()
            return []
        }

        guard process.terminationStatus == 0 else { return [] }
        return ClaudeBackgroundAgentReconciler.parse(agentsJSON: output.get())
    }

    private func resolvedClaudeLaunchPlan() -> AgentSessionLaunchPlan? {
        try? AgentExecutableResolver(
            configuredExecutablePaths: AgentExecutableResolver.cmuxConfiguredExecutablePaths()
        ).resolve(.claude)
    }

    /// Holds the non-`Sendable` `Process`/`FileHandle` for use inside the background read and
    /// the termination escalation without tripping strict-concurrency capture checks; the
    /// objects are only touched from this single probe.
    private final class ProbeBox: @unchecked Sendable {
        let process: Process
        let readHandle: FileHandle
        init(process: Process, readHandle: FileHandle) {
            self.process = process
            self.readHandle = readHandle
        }
    }

    private final class DataBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Data()
        func set(_ data: Data) { lock.lock(); value = data; lock.unlock() }
        func get() -> Data { lock.lock(); defer { lock.unlock() }; return value }
    }
}
