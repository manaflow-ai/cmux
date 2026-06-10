import AppKit
import Bonsplit
import CMUXAgentLaunch
import Combine
import Darwin
import Foundation
import os
import SQLite3


// MARK: - Scanning and deep search pipeline
extension SessionIndexStore {
    struct LoadedAgentOrder: Sendable {
        let agents: [SessionAgent]
        let registry: CmuxVaultAgentRegistry
    }

    nonisolated static func defaultAgentOrder(workingDirectory: String?) async -> LoadedAgentOrder {
        await Task.detached(priority: .utility) {
            defaultAgentOrderSync(workingDirectory: workingDirectory)
        }.value
    }

    nonisolated private static func defaultAgentOrderSync(workingDirectory: String?) -> LoadedAgentOrder {
        let builtInIDs = Set(SessionAgent.builtInCases.map(\.rawValue))
        let registry = CmuxVaultAgentRegistry.load(workingDirectory: workingDirectory)
        let agents = SessionAgent.builtInCases + registry.registrations.compactMap {
            builtInIDs.contains($0.id) ? nil : .registered(RegisteredSessionAgent(registration: $0))
        }
        return LoadedAgentOrder(agents: agents, registry: registry)
    }

    nonisolated private static func vaultAgentRegistry(workingDirectory: String?) async -> CmuxVaultAgentRegistry {
        await Task.detached(priority: .utility) {
            CmuxVaultAgentRegistry.load(workingDirectory: workingDirectory)
        }.value
    }

    private static let perAgentLimit = 30
    /// Hard cap on candidate files inspected per call to keep deep-page searches bounded.
    nonisolated static let searchMaxFiles = 1500

    static func scanAll() async -> [SessionEntry] {
        // Initial scan errors are silently ignored — UI just shows the cached
        // entries we did get. Errors get surfaced when the user actively
        // searches via the popover.
        let bag = ErrorBag()
        let order = await defaultAgentOrder(workingDirectory: nil)
        let combined = await loadAgents(
            order.agents,
            registry: order.registry,
            needle: "",
            cwdFilter: nil,
            offset: 0,
            limit: perAgentLimit,
            errorBag: bag
        )
        return combined.sorted { $0.modified > $1.modified }
    }

    enum SearchScope {
        case agent(SessionAgent)
        /// Filter by absolute cwd; nil/"" = unknown-folder bucket.
        case directory(String?)
    }

    /// What the popover gets back. `errors` is non-empty when one or more
    /// agents failed to read their data source (schema mismatch, file missing,
    /// SQL error). UI should surface them so users see why the list looks
    /// short or empty rather than thinking nothing matched.
    struct SearchOutcome: Sendable {
        var entries: [SessionEntry]
        var errors: [String]
    }

    /// Thread-safe accumulator passed down to per-agent helpers so they can
    /// report failures (e.g. SQL prepare errors when an agent bumps its
    /// schema) without requiring the helpers to throw across actor boundaries.
    final class ErrorBag: @unchecked Sendable {
        private let lock = NSLock()
        private var messages: [String] = []
        func add(_ msg: String) {
            lock.lock(); defer { lock.unlock() }
            messages.append(msg)
        }
        func snapshot() -> [String] {
            lock.lock(); defer { lock.unlock() }
            return messages
        }
    }

    /// Paginated on-demand search across the full filesystem (Claude/Codex) and
    /// SQLite (OpenCode). Empty query is allowed and returns the most-recent
    /// entries (used when the user just opens the popover and scrolls).
    /// Returns up to `limit` entries sorted by mtime desc, skipping the first
    /// `offset` matches.
    func searchSessions(
        query: String,
        scope: SearchScope,
        offset: Int,
        limit: Int
    ) async -> SearchOutcome {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let needle = trimmed.lowercased()
        let bag = ErrorBag()
        #if DEBUG
        let totalStart = ProcessInfo.processInfo.systemUptime
        defer {
            let totalMs = (ProcessInfo.processInfo.systemUptime - totalStart) * 1000
            cmuxDebugLog("session.search.total ms=\(String(format: "%.0f", totalMs)) needle=\"\(trimmed.prefix(20))\" offset=\(offset) limit=\(limit) errors=\(bag.snapshot().count)")
        }
        #endif
        let entries: [SessionEntry]
        switch scope {
        case .agent(let a):
            let registry: CmuxVaultAgentRegistry
            let cwdFilter: String?
            if case .registered = a {
                let scopedCwd = currentDirectory?.trimmingCharacters(in: .whitespacesAndNewlines)
                cwdFilter = scopedCwd?.isEmpty == false ? scopedCwd : nil
                registry = await Self.vaultAgentRegistry(workingDirectory: cwdFilter)
            } else if a == .grok {
                let scopedCwd = currentDirectory?.trimmingCharacters(in: .whitespacesAndNewlines)
                cwdFilter = scopedCwd?.isEmpty == false ? scopedCwd : nil
                registry = await Self.vaultAgentRegistry(
                    workingDirectory: cwdFilter
                )
            } else {
                cwdFilter = nil
                registry = CmuxVaultAgentRegistry(registrations: [])
            }
            entries = await Self.searchAgent(
                needle: needle, agent: a, cwdFilter: cwdFilter,
                offset: offset, limit: limit, errorBag: bag, registry: registry
            )
        case .directory(let path):
            let noFolderScope = (path == nil) || ((path ?? "").isEmpty)
            let cwdFilter = noFolderScope ? nil : path
            // Multi-agent merge: fetch the union of (offset+limit) per agent so the
            // merge-sort can produce a stable global ordering, then slice.
            let target = offset + limit
            let order = await Self.defaultAgentOrder(workingDirectory: cwdFilter)
            var merged = await Self.loadAgents(
                order.agents,
                registry: order.registry,
                needle: needle,
                cwdFilter: cwdFilter,
                offset: 0,
                limit: target,
                errorBag: bag
            )
            if noFolderScope {
                merged = merged.filter { ($0.cwd ?? "").isEmpty }
            }
            let sorted = merged.sorted { $0.modified > $1.modified }
            entries = Array(sorted.dropFirst(offset).prefix(limit))
        }
        return SearchOutcome(entries: entries, errors: bag.snapshot())
    }

    nonisolated static func loadAgents(
        _ agents: [SessionAgent],
        registry: CmuxVaultAgentRegistry,
        needle: String,
        cwdFilter: String?,
        offset: Int,
        limit: Int,
        errorBag: ErrorBag
    ) async -> [SessionEntry] {
        await withTaskGroup(of: [SessionEntry].self) { group in
            for agent in agents {
                group.addTask {
                    await timedAgent(
                        needle: needle,
                        agent: agent,
                        cwdFilter: cwdFilter,
                        offset: offset,
                        limit: limit,
                        errorBag: errorBag,
                        registry: registry
                    )
                }
            }
            var merged: [SessionEntry] = []
            for await entries in group {
                merged.append(contentsOf: entries)
            }
            return merged
        }
    }

    nonisolated private static func timedAgent(
        needle: String, agent: SessionAgent, cwdFilter: String?,
        offset: Int, limit: Int, errorBag: ErrorBag,
        registry: CmuxVaultAgentRegistry
    ) async -> [SessionEntry] {
        #if DEBUG
        let start = ProcessInfo.processInfo.systemUptime
        let result = await searchAgent(
            needle: needle,
            agent: agent,
            cwdFilter: cwdFilter,
            offset: offset,
            limit: limit,
            errorBag: errorBag,
            registry: registry
        )
        let ms = (ProcessInfo.processInfo.systemUptime - start) * 1000
        cmuxDebugLog("session.search.agent agent=\(agent.rawValue) ms=\(String(format: "%.0f", ms)) results=\(result.count) cwd=\(cwdFilter?.suffix(40) ?? "nil")")
        return result
        #else
        return await searchAgent(
            needle: needle,
            agent: agent,
            cwdFilter: cwdFilter,
            offset: offset,
            limit: limit,
            errorBag: errorBag,
            registry: registry
        )
        #endif
    }

    nonisolated private static func searchAgent(
        needle: String, agent: SessionAgent, cwdFilter: String?,
        offset: Int, limit: Int, errorBag: ErrorBag,
        registry: CmuxVaultAgentRegistry
    ) async -> [SessionEntry] {
        switch agent {
        case .claude: return await loadClaudeEntries(needle: needle, cwdFilter: cwdFilter, offset: offset, limit: limit)
        case .codex: return await loadCodexEntries(needle: needle, cwdFilter: cwdFilter, offset: offset, limit: limit, errorBag: errorBag)
        case .grok:
            return await loadGrokEntries(
                registration: registry.registration(id: "grok") ?? .builtInGrok,
                needle: needle,
                cwdFilter: cwdFilter,
                offset: offset,
                limit: limit
            )
        case .opencode: return loadOpenCodeEntries(needle: needle, cwdFilter: cwdFilter, offset: offset, limit: limit, errorBag: errorBag)
        case .rovodev: return loadRovoDevEntries(needle: needle, cwdFilter: cwdFilter, offset: offset, limit: limit, errorBag: errorBag)
        case .hermesAgent: return loadHermesAgentEntries(needle: needle, cwdFilter: cwdFilter, offset: offset, limit: limit, errorBag: errorBag)
        case .registered(let agent):
            guard let registration = registry.registration(id: agent.id) else {
                return []
            }
            return await loadRegisteredAgentEntries(
                registration: registration,
                needle: needle,
                cwdFilter: cwdFilter,
                offset: offset,
                limit: limit
            )
        }
    }

    /// Path to `rg` (ripgrep), if installed. nil when not found — the search
    /// code falls back to the Foundation substring scan.
    nonisolated private static func resolvedRipgrepPath() -> String? {
        switch RipgrepExecutableResolver.resolution() {
        case .found(let executable):
            return executable.url.path
        case .configuredPathNotExecutable(let path):
            sessionIndexLogger.warning(
                "Configured ripgrep path is not executable; falling back to Foundation session search: \(path, privacy: .public)"
            )
            return nil
        case .notFound:
            return nil
        }
    }

    /// Run `rg --files-with-matches --ignore-case --fixed-strings` for `needle`
    /// under `root`, restricted to `glob` (e.g. `*.jsonl`). Returns matched file
    /// URLs, or nil if rg isn't available or the run failed (caller falls back).
    ///
    /// Async by design so we can wire cancellation: when the awaiting Task is
    /// cancelled (e.g. user types another key), `onCancel` signals the launched
    /// rg process instead of letting it grind to completion.
    nonisolated static func ripgrepMatchingPaths(
        needle: String, root: String, fileGlob: String, ripgrepPath: String? = nil
    ) async -> [URL]? {
        guard let rg = ripgrepPath ?? resolvedRipgrepPath() else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: rg)
        process.arguments = [
            "--files-with-matches",
            "--ignore-case",
            "--fixed-strings",
            "--no-messages",
            "--no-ignore",
            "--hidden",
            "--glob", fileGlob,
            "--",
            needle,
            root,
        ]
        let outPipe = Pipe()
        process.standardOutput = outPipe
        // Discard stderr to /dev/null so its pipe can never deadlock either.
        if let nullDev = FileHandle(forWritingAtPath: "/dev/null") {
            process.standardError = nullDev
        }
        let cancellation = SessionIndexRipgrepCancellation()
        process.terminationHandler = { process in
            cancellation.markFinished(processIdentifier: process.processIdentifier)
        }

        return await withTaskCancellationHandler {
            guard !Task.isCancelled else { return [] }
            do {
                try process.run()
            } catch {
                if Task.isCancelled { return [] }
                return nil as [URL]?
            }
            cancellation.markStarted(processIdentifier: process.processIdentifier)
            if Task.isCancelled {
                cancellation.cancel()
            }
            // Drain stdout BEFORE waitUntilExit. With many matches rg writes
            // more than the ~64 KB pipe buffer; reading until EOF lets rg
            // make progress and EOF arrives when rg closes its stdout on exit.
            // Once the pipe read returns, the process is already exiting,
            // so waitUntilExit is essentially instant — we just need it to make
            // terminationStatus observable. (Setting terminationHandler here
            // would race: if rg already exited, the handler is registered too
            // late and never fires → deadlock.)
            let data = ProcessPipeReader.readDataToEndOfFileOrEmpty(from: outPipe.fileHandleForReading)
            process.waitUntilExit()
            cancellation.markFinished(processIdentifier: process.processIdentifier)
            if Task.isCancelled { return [] }
            // rg exit codes: 0 = matches, 1 = no matches, 2 = error/terminated.
            switch process.terminationStatus {
            case 0:
                guard let str = String(data: data, encoding: .utf8) else { return nil as [URL]? }
                return str.split(separator: "\n", omittingEmptySubsequences: true)
                    .map { URL(fileURLWithPath: String($0)) }
            case 1:
                return []
            default:
                return nil
            }
        } onCancel: {
            // Fires synchronously when the awaiting Task is cancelled. SIGTERM
            // closes stdout, lets the pipe read return, and unblocks the
            // body so this call can complete cleanly.
            cancellation.cancel()
        }
    }

}
