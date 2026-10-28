public import Foundation

/// How a started bootstrap ended, for a caller that needs its clone (the New Cloud Workspace
/// wizard's "From repository" opens the project at ``Completion/finished(repoPath:)``). The
/// machine's runner says it in ``statusPath``; ``waitForRun(on:bound:)`` reads it once the runner
/// lets go of its `alive` lock, the lock a machine-config apply waits on too.
extension CloudMachineBootstrap {
    /// The run's end, in words a person reads (the app's `waitForCompletion(on:)` localizes ``Run``).
    public enum Completion: Equatable, Sendable {
        /// The script, and the clone when one was asked, finished. `repoPath` is the clone's absolute
        /// path on the machine (`/home/cmux/work/NAME`); nil without a repo.
        case finished(repoPath: String?)
        case failed(reason: String)
        /// A failed repository can be retried without repeating machine creation.
        case repositoryFailed(reason: String)
    }

    /// The run's end as ``statusPath`` says it, before it becomes words.
    public enum Run: Equatable, Sendable {
        case finished(repoPath: String?)
        /// The repo step found no GitHub access to `repo` (`OWNER/NAME`) on the machine.
        case needsGitHub(repo: String)
        /// GitHub could not find the repository or conceals it because access is missing.
        case repoNotFound(repo: String)
        /// The machine could not reach GitHub (DNS, connection failure or timeout).
        case repoOffline(repo: String)
        /// The clone or update of `repo` failed (another repository in its folder, a missing ref…).
        case repoFailed(repo: String)
        case scriptFailed(exitCode: Int)
        /// The start's runner never took over (it came a minute late, or not at all).
        case runnerNeverCame
        /// The runner ended without writing its end (killed, or the machine restarted).
        case stopped
        /// The wait's bound passed (or the wait was cancelled) while the runner still ran.
        case stillRunning
        /// The machine did not answer three reads in a row; the last error's text.
        case unreachable(String)
    }

    /// How long one read waits on the runner's lock: under the exec API's limit
    /// (``Machine/init(api:machineID:)`` gives each exec 20 s), so a long run is several reads.
    public static let completionLockWait = 15

    /// One read: waits (`flock -s -w`) while a runner holds `alive`, which it holds for its whole life and the
    /// kernel drops however it ends, and reads ``statusPath`` while it holds the lock shared, so a runner can't
    /// take over between the two (a runner writes its status only while it holds `alive`). It prints whether
    /// the lock was `free`, `held` (the wait ran out: read again) or `none` (no runner made it yet), the
    /// machine's clock, and the status. The lock is let go at once, like the applier's probe: a runner about to
    /// take it waits a moment at most. Only a start whose runner has not taken over yet (`starting`, normally a
    /// few milliseconds) has no lock to wait on: that read waits one second first, so a runner that never comes
    /// costs one read a second until its minute is up.
    public static var waitCommand: String { [
        "set -u", "d=\(directory)", "u=\(user)", #"h=$(getent passwd "$u" | cut -d: -f6)"#, noSymlinks,
        #"if grep -q '"state":"starting"' "$d/status.json" 2>/dev/null; then sleep 1; fi"#,
        // The clock is read just before the status, under the same lock: a `starting` never looks older than it is.
        #"w=none; s=''; n=$(date +%s)"#,
        #"if [ -f "$d/alive" ] && [ ! -L "$d/alive" ] && exec 8<"$d/alive"; then if flock -s -w \#(completionLockWait) 8; then w=free; n=$(date +%s); s=$(cat "$d/status.json" 2>/dev/null || true); else w=held; fi; exec 8<&-; else n=$(date +%s); s=$(cat "$d/status.json" 2>/dev/null || true); fi"#,
        #"printf 'cmux-wait %s %s\n%s\n' "$w" "$n" "$s""#,
    ].joined(separator: "; ") }

    /// One read's answer: the run's end, or read again (`wait`), or an answer that says nothing (`unreadable`).
    enum Read: Equatable {
        case ended(Run)
        case wait
        case unreadable
    }

    /// Waits for the run a start began (`started`, `running` or `skipped`) to end: one ``waitCommand`` after
    /// another, each blocked on the runner's lock, until ``statusPath`` says the run ended or `bound` passes.
    /// No read sleeps between runs of the lock. Three failed reads in a row end it as ``Run/unreachable(_:)``;
    /// a cancelled wait ends as ``Run/stillRunning``. Every read that says read again takes at least a second
    /// (a `starting` read waits one, a running one up to ``completionLockWait``), so one read a second of
    /// `bound` is enough reads.
    public func waitForRun(on machine: Machine, bound: Duration = .seconds(3 * 3600)) async -> Run {
        let clock = ContinuousClock(), deadline = clock.now.advanced(by: bound)
        var failures = 0
        for _ in 0...max(0, bound.components.seconds) {
            guard !Task.isCancelled else { break }
            var last = ""
            do {
                switch Self.read(try await machine.exec(Self.waitCommand), repo: repo) {
                case let .ended(run): return run
                case .wait: failures = 0
                case .unreadable: failures += 1; last = "unreadable answer"
                }
            } catch {
                // An exec cut off at its timeout is read again; a machine that never answers is not.
                failures += 1
                last = String(describing: error)
            }
            // Cancelled during the read: the run's end is unknown, never the machine's fault.
            guard !Task.isCancelled else { break }
            if failures >= 3 { return .unreachable(last) }
            if clock.now >= deadline { break }
        }
        return .stillRunning
    }

    /// One ``waitCommand`` answer. `repo` is what this bootstrap asked to clone (nil: no repo).
    static func read(_ ran: CloudExecResult, repo: CloudMachineRepo?) -> Read {
        var lines = ran.stdout.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard ran.exitCode == 0, let first = lines.firstIndex(where: { $0.hasPrefix("cmux-wait ") }) else { return .unreadable }
        let head = lines[first].split(separator: " ")
        lines.removeSubrange(...first)
        guard head.count == 3, let now = Int(head[2]) else { return .unreadable }
        let lock = head[1]
        if lock == "held" { return .wait }
        let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        // No status at all: no start ever got as far as `starting` here.
        if text.isEmpty { return .ended(.runnerNeverCame) }
        guard let status = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let state = status["state"] as? String else { return .unreadable }
        let code = status["exit_code"] as? Int
        let cloned = status["repo"] as? [String: Any]
        let repoStatus = cloned?["status"] as? String
        let repoFailure: (String) -> Run = { name in
            switch repoStatus {
            case "needs_github": .needsGitHub(repo: name)
            case "not_found": .repoNotFound(repo: name)
            case "offline": .repoOffline(repo: name)
            default: .repoFailed(repo: name)
            }
        }
        let name = repo.map { "\($0.owner)/\($0.name)" } ?? (cloned?["url"] as? String) ?? ""
        switch state {
        case "done":
            guard let repo else { return .ended(.finished(repoPath: nil)) }
            guard repoStatus.map({ ["cloned", "updated", "kept"].contains($0) }) ?? true else {
                return .ended(repoFailure(name))
            }
            let dir = (cloned?["dir"] as? String).flatMap { $0.hasPrefix("/") ? $0 : nil }
            return .ended(.finished(repoPath: dir ?? "/home/\(user)/\(repo.directory)"))
        case "failed":
            // The runner's own refusal when it came a minute after its start (`"late":true`), before any step.
            if status["late"] as? Bool == true { return .ended(.runnerNeverCame) }
            // `step` says which step failed; a runner from before it (no `step`) is read from the repo status.
            let repoStep = (status["step"] as? String).map { $0 == "repo" }
                ?? (["failed", "not_found", "offline"].contains(repoStatus ?? "") || (repoStatus == "needs_github" && code == CloudMachineRepo.needsGitHubExit))
            guard repoStep else { return .ended(.scriptFailed(exitCode: code ?? -1)) }
            return .ended(repoFailure(name))
        case "running":
            // Read under a free `alive`: the runner that wrote `running` is gone. Without an `alive` the read
            // raced the runner making it (the next read sees it); counted as a failed read, so it never spins.
            return lock == "free" ? .ended(.stopped) : .unreadable
        case "starting":
            let at = status["at"] as? Int ?? now
            return now - at >= 60 ? .ended(.runnerNeverCame) : .wait
        default:
            return .unreadable
        }
    }
}
