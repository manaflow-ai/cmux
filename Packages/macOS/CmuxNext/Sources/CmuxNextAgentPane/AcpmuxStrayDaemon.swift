import Darwin
import Foundation
import os
import CmuxNextCompat
import CmuxNextWakeups

/// A daemon on this app's acpmux home that no cmux install runs (hq
/// plans/cmux-next/acpmux-one-daemon.md, step 2): a `~/.local/bin/acpmux` started by launchd or
/// by the CLI's autostart. The server peer check refuses it (its executable is not this app's),
/// so the app takes it over instead, the way it hands off another build
/// (``AcpmuxVersionHandoff``): its agents detach and the bundled daemon adopts them. A launchd
/// job that would start it again is booted out first. Only a daemon that runs its
/// agents under agent hosts is taken over; an older one would end its agents, so it keeps
/// running and stays refused.
nonisolated enum AcpmuxStrayDaemon {
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "agent-pane.acpmux")
    /// Daemons (by pid) this process already took over: never twice.
    private static let handedOff = Mutex<Set<Int32>>([])

    /// Whether a daemon run from `runningPath` is stray for an app that runs `executable`: neither
    /// this app's acpmux nor one inside an app bundle (another cmux install, which the peer check's
    /// own rules decide).
    static func isStray(runningPath: String?, executable: URL) -> Bool {
        guard let runningPath else { return false }
        let running = URL(fileURLWithPath: runningPath).resolvingSymlinksInPath().path
        guard running != executable.resolvingSymlinksInPath().path else { return false }
        return !running.contains(".app/Contents/")
    }

    /// Labels of the jobs in `launchctl print gui/<uid>`'s `services` list whose pid is one of
    /// `pids`. Each row is `PID STATUS LABEL`; a job that does not run shows pid 0 or `-`. An app
    /// (`application.*`) is never one: booting it out would quit it.
    static func labels(runningAnyOf pids: Set<Int32>, fromDomainPrint output: String) -> [String] {
        var inServices = false
        var labels: [String] = []
        for line in output.split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            if !inServices {
                inServices = text == "services = {"
                continue
            }
            if text == "}" { break }
            let columns = text.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if columns.count >= 3, let pid = Int32(columns[0]), pid > 1, pids.contains(pid), !columns[2].hasPrefix("application.") {
                labels.append(String(columns[2]))
            }
        }
        return labels
    }

    /// The pid in `launchctl print gui/<uid>/<label>` output (`pid = N`), nil when the job does not run.
    static func pid(fromLaunchctlPrint output: String) -> Int32? {
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, parts[0] == "pid", let pid = Int32(parts[1]) { return pid }
        }
        return nil
    }

    /// Takes over the daemon described by `status` when it is stray. Returns true when it stopped
    /// that daemon, so the caller starts the bundled one. Who it is comes from the socket's own
    /// peer (`LOCAL_PEERPID`), never from the pid the daemon reports alone.
    static func handOffIfStray(_ status: AcpmuxStatus, environment: AcpmuxEnvironment) async -> Bool {
        guard let peer = AcpmuxServerPeer.socketPeer(socketPath: environment.socketPath), peer.uid == getuid(),
              let pid = status.pid, peer.pid == pid,
              isStray(runningPath: peer.executablePath, executable: environment.executable) else { return false }
        let path = peer.executablePath
        guard status.agentHosts else {
            logger.error("acpmux \(pid) at \(path, privacy: .public) is not this app's and has no agent hosts; its agents would end, so it keeps running")
            return false
        }
        guard handedOff.withLock({ $0.insert(pid).inserted }) else { return false }
        logger.info("acpmux \(pid) at \(path, privacy: .public) is not this app's; taking it over")
        // launchd's SIGTERM detaches its agents like a shutdown. A bootout that fails falls back
        // to the shutdown request.
        if await bootOutLaunchdJob(runningPID: pid), await AgentPaneProcessExit(pid: pid).event(within: .seconds(15)) {
            return true
        }
        do {
            try await AcpmuxStatusClient.shutdown(socketPath: environment.socketPath, home: environment.home)
        } catch {
            logger.error("acpmux takeover request failed: \(String(describing: error), privacy: .public)")
            return false
        }
        // The old daemon holds its lock until it exits; the new one needs it.
        return await AgentPaneProcessExit(pid: pid).event(within: .seconds(15))
    }

    /// Boots out this user's launchd job whose own process is daemon `runningPID` (`acpmux host
    /// setup`'s `com.acpmux.daemon` runs it directly), so KeepAlive does not start it again. Not
    /// its parent: that may be a terminal or another job that only started it, and a bootout
    /// would end it. It is not disabled: `acpmux host setup`
    /// and `update` bootstrap that same agent, and launchd refuses to bootstrap a disabled one. A
    /// later login may start it again; the app takes it over again then. True when it booted one out.
    /// `stillRunning`, when given: whether that very process still runs, checked right before the
    /// bootout, so a pid the daemon freed and another process took is never booted out in its name.
    static func bootOutLaunchdJob(runningPID: Int32, stillRunning: (@Sendable () -> Bool)? = nil) async -> Bool {
        let pids: Set<Int32> = [runningPID]
        let domain = "gui/\(getuid())"
        for label in labels(runningAnyOf: pids, fromDomainPrint: await launchctl(["print", domain]).output) {
            // The job's own record must name the same process: the list is a snapshot.
            guard let named = pid(fromLaunchctlPrint: await launchctl(["print", "\(domain)/\(label)"]).output),
                  pids.contains(named) else { continue }
            if let stillRunning, !stillRunning() { return false }
            logger.info("acpmux \(runningPID) runs under launchd \(label, privacy: .public); booting it out")
            return await launchctl(["bootout", "\(domain)/\(label)"]).status == 0
        }
        return false
    }

    private static func launchctl(_ arguments: [String]) async -> (status: Int32, output: String) {
        // Awaited without a thread: a launchctl wait never holds a cooperative-pool thread.
        guard let outcome = try? await AsyncProcess().run(ProcessRequest(URL(fileURLWithPath: "/bin/launchctl"), arguments))
        else { return (-1, "") }
        return (outcome.status, outcome.text)
    }
}
