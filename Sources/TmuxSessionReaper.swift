import Foundation

/// Lifecycle for tmux sessions that cmux workspaces own.
///
/// Launcher scripts that wrap an agent in a persistent `tmux new-session -A` (see
/// `claude-remote`) register the session name against their workspace with
/// `cmux set-tmux-session`. That registration is what makes the session *owned*:
///
/// - Closing the workspace deliberately kills the session, so the agent inside it
///   does not stay resident forever holding its whole heap.
/// - A session nobody registered is never touched.
/// - A cmux crash never runs `closeWorkspace`, so crash-resilient reattach — the
///   reason those wrappers use `new-session -A` in the first place — still works.
///
/// `prune` is the reconcile pass behind the "Clear Orphaned tmux Sessions" command:
/// every live session that no open workspace claims is an orphan. cmux is the only
/// thing that can compute this correctly, because the session name is derived from
/// the workspace's directory *and* its instance index, and the instance index is not
/// recoverable from outside the app.
enum TmuxSessionReaper {

    /// Resolved once: tmux is a Homebrew binary whose prefix differs by architecture,
    /// and a GUI app does not inherit the user's shell PATH.
    static let tmuxPath: String? = {
        let candidates = [
            "/opt/homebrew/bin/tmux",
            "/usr/local/bin/tmux",
            "/usr/bin/tmux",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    /// Names of every session on the current user's tmux server.
    /// Empty when tmux is absent or no server is running — both are normal.
    static func liveSessions() -> [String] {
        guard let tmuxPath else { return [] }
        guard let output = run(tmuxPath, ["list-sessions", "-F", "#{session_name}"]) else {
            return []
        }
        return output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Every live session with the directory it was started in.
    ///
    /// The directory is the only dependable link back to a workspace. A session's *name*
    /// is chosen by the wrapper and cannot be recomputed from the workspace: the instance
    /// index in the sidebar need not match the one in the name (a workspace at index 56
    /// routinely owns a session called plain `azdevops`), and an explicit lane word does
    /// not appear in the workspace at all. `session_path` sidesteps both.
    static func liveSessionsWithPaths() -> [(session: String, directory: String)] {
        guard let tmuxPath else { return [] }
        guard let output = run(
            tmuxPath,
            ["list-sessions", "-F", "#{session_name}\t#{session_path}"]
        ) else {
            return []
        }
        return output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            let session = parts[0].trimmingCharacters(in: .whitespaces)
            let directory = parts[1].trimmingCharacters(in: .whitespaces)
            guard !session.isEmpty, !directory.isEmpty else { return nil }
            return (session, directory)
        }
    }

    /// Lowercase, with spaces and dots folded to hyphens.
    ///
    /// Mirrors `slugify()` in `claude-remote` (`tr '[:upper:]' '[:lower:]' | tr ' .' '-'`).
    /// The two must agree exactly: the wrapper picks the session name, and this is how
    /// cmux predicts it.
    static func slugify(_ value: String) -> String {
        String(value.lowercased().map { $0 == " " || $0 == "." ? "-" : $0 })
    }

    /// The tmux session name an agent wrapper will pick for this workspace.
    ///
    /// `claude-remote` and its siblings derive the name from the workspace directory's
    /// basename, suffixed with the instance index when it is above 1 (instance 1 is the
    /// bare name). Predicting it is what lets cmux recognise a still-live session after a
    /// crash, when nothing has registered ownership yet.
    ///
    /// Not total: the wrappers also accept an explicit *word* suffix (`claude-remote -n
    /// boards`), which is not recoverable from the workspace alone. Such sessions simply
    /// will not be predicted — callers must treat a derived name as a candidate to
    /// intersect with the live session list, never as proof a session exists.
    static func sessionName(directory: String, instanceIndex: Int) -> String {
        sessionName(directory: directory, instanceIndex: instanceIndex, agent: .unprefixed)
    }

    /// The same prediction for a specific agent. `codex-remote` prefixes its session
    /// with `cx-` so a Codex lane and a Claude lane on one directory stay separate;
    /// predicting only the bare name makes every Codex lane invisible to reattach,
    /// restore and the orphan check.
    static func sessionName(directory: String, instanceIndex: Int, agent: WorkspaceAgent) -> String {
        let base = slugify((directory as NSString).lastPathComponent)
        guard !base.isEmpty else { return "" }
        let indexed = instanceIndex > 1 ? "\(base)-\(instanceIndex)" : base
        return agent.sessionPrefix + indexed
    }

    /// Lowercase ASCII letters and digits, every other run folded to one hyphen, trimmed.
    ///
    /// Mirrors `slugify()` in `cmux-lane-session` (`sed -E 's/[^a-z0-9]+/-/g'`).
    static func laneSlug(_ value: String) -> String {
        var out = ""
        var pendingHyphen = false
        for scalar in value.lowercased().unicodeScalars {
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) {
                if pendingHyphen && !out.isEmpty { out.append("-") }
                pendingHyphen = false
                out.unicodeScalars.append(scalar)
            } else {
                pendingHyphen = true
            }
        }
        return out
    }

    /// The name the wrappers pick today, from the workspace title.
    ///
    /// The instance index is a per-host counter, so a name built on it differs between
    /// Macs for the same workspace. `cmux-lane-session name` is the source of truth; this
    /// must agree with it exactly:
    ///
    /// - no title: the legacy basename-and-instance name;
    /// - a title that names the repo (`rodchristiansen · cmux`, `Personal - Nutrition`,
    ///   optionally ending in a duplicate's ` (N)`): the legacy name, unchanged;
    /// - any other title: the slugified title, duplicate suffix included.
    static func sessionName(
        directory: String,
        title: String,
        instanceIndex: Int,
        agent: WorkspaceAgent
    ) -> String {
        let legacy = sessionName(directory: directory, instanceIndex: instanceIndex, agent: agent)
        let titled = laneSlug(title)
        guard !titled.isEmpty else { return legacy }
        let core = laneSlug(title.replacingOccurrences(
            of: #" \([0-9]+\)$"#, with: "", options: .regularExpression
        ))
        let base = laneSlug((directory as NSString).lastPathComponent)
        if !base.isEmpty, core == base || core.hasSuffix("-" + base) {
            return legacy
        }
        return agent.sessionPrefix + titled
    }

    /// Every name a live session of this workspace may carry, current rule first.
    ///
    /// Sessions started before the title rule keep their legacy name until they end, so
    /// both spellings belong to the workspace for reattach and the orphan check.
    static func sessionNames(
        directory: String,
        title: String,
        instanceIndex: Int,
        agent: WorkspaceAgent
    ) -> [String] {
        let current = sessionName(directory: directory, title: title,
                                  instanceIndex: instanceIndex, agent: agent)
        let legacy = sessionName(directory: directory, instanceIndex: instanceIndex, agent: agent)
        return [current, legacy].reduce(into: [String]()) { names, name in
            if !name.isEmpty, !names.contains(name) { names.append(name) }
        }
    }

    /// tmux arguments for killing exactly one session.
    ///
    /// The `=` prefix forces an exact match. A bare `-t name` falls back to prefix and
    /// then fnmatch, so killing `azdevops` could take `azdevops-40` with it. Split out
    /// as a pure function so that contract is unit-testable without spawning tmux.
    static func killArguments(for session: String) -> [String] {
        ["kill-session", "-t", "=\(session)"]
    }

    /// Kill one session. Returns false if tmux is missing or the session is already gone.
    @discardableResult
    static func kill(_ session: String) -> Bool {
        guard let tmuxPath, !session.isEmpty else { return false }
        return run(tmuxPath, killArguments(for: session)) != nil
    }

    /// Sessions in `live` that no open workspace has registered.
    ///
    /// Pure seam: the shell-free half of `orphans(ownedSessions:)`, so the ownership
    /// rule can be tested against a fixed session list.
    static func orphans(live: [String], ownedSessions: Set<String>) -> [String] {
        live.filter { !ownedSessions.contains($0) }
    }

    /// Live sessions that no open workspace has registered.
    static func orphans(ownedSessions: Set<String>) -> [String] {
        orphans(live: liveSessions(), ownedSessions: ownedSessions)
    }

    /// Run a command and return its stdout, or nil on failure or timeout.
    ///
    /// Never uses `waitUntilExit`: it spins the current run loop, and on the main
    /// thread that re-entered SwiftUI layout mid-update and froze the app for hours.
    /// Output is drained on a background queue and the wait is a plain semaphore, so a
    /// hung child costs at most `timeout` and is then terminated.
    static func run(_ launchPath: String, _ arguments: [String], timeout: TimeInterval = 3) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            return nil
        }

        var data = Data()
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            drained.signal()
        }

        guard exited.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            return nil
        }
        guard drained.wait(timeout: .now() + 1) == .success else { return nil }
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
