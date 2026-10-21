import Darwin
import Foundation
import os
import CmuxNextCompat

/// A daemon on this app's acpmux home that no cmux install runs (hq
/// plans/cmux-next/acpmux-one-daemon.md, step 2): a `~/.local/bin/acpmux` started by launchd or
/// by the CLI's autostart. The server peer check refuses it (its executable is not this app's),
/// so the app takes it over instead, the way it hands off another build
/// (``AcpmuxVersionHandoff``): its agents detach and the bundled daemon adopts them. A launchd
/// agent that would start it again is disabled and booted out first. Only a daemon that runs its
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

    /// Labels of the launchd agents among `agents` (each a LaunchAgents plist) whose program is
    /// `programPath` (`Program`, else the first of `ProgramArguments`, symlinks resolved).
    static func launchAgentLabels(programPath: String, agents: [[String: Any]]) -> [String] {
        let target = URL(fileURLWithPath: programPath).resolvingSymlinksInPath().path
        return agents.compactMap { agent in
            guard let label = agent["Label"] as? String,
                  let program = agent["Program"] as? String ?? (agent["ProgramArguments"] as? [String])?.first else { return nil }
            return URL(fileURLWithPath: program).resolvingSymlinksInPath().path == target ? label : nil
        }
    }

    /// The pid in `launchctl print` output (`pid = N`), nil when the job does not run.
    static func pid(fromLaunchctlPrint output: String) -> Int32? {
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, parts[0] == "pid", let pid = Int32(parts[1]) { return pid }
        }
        return nil
    }

    /// Takes over the daemon described by `status` when it is stray. Returns true when it stopped
    /// that daemon, so the caller starts the bundled one.
    static func handOffIfStray(_ status: AcpmuxStatus, environment: AcpmuxEnvironment) async -> Bool {
        guard let pid = status.pid, let path = AcpmuxVersionHandoff.executablePath(pid: pid),
              isStray(runningPath: path, executable: environment.executable) else { return false }
        guard status.agentHosts else {
            logger.error("acpmux \(pid) at \(path, privacy: .public) is not this app's and has no agent hosts; its agents would end, so it keeps running")
            return false
        }
        guard handedOff.withLock({ $0.insert(pid).inserted }) else { return false }
        logger.info("acpmux \(pid) at \(path, privacy: .public) is not this app's; taking it over")
        if await bootOutLaunchAgent(runningPID: pid, programPath: path) {
            // launchd's SIGTERM detaches its agents like a shutdown.
            return await AgentPaneProcessExit(pid: pid).event(within: .seconds(15))
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

    /// Disables and boots out this user's launchd agent that runs daemon `runningPID`, so it does
    /// not start the stray daemon again. True when it booted one out.
    static func bootOutLaunchAgent(runningPID: Int32, programPath: String) async -> Bool {
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let agents: [[String: Any]] = files.filter { $0.pathExtension == "plist" }.compactMap { file in
            // concurrency-allow: small plist reads, off the main actor in the pane host's daemon start
            guard let data = try? Data(contentsOf: file) else { return nil }
            return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
        }
        let domain = "gui/\(getuid())"
        for label in launchAgentLabels(programPath: programPath, agents: agents) {
            guard pid(fromLaunchctlPrint: await launchctl(["print", "\(domain)/\(label)"]).output) == runningPID else { continue }
            logger.info("acpmux \(runningPID) runs under launchd \(label, privacy: .public); disabling and booting it out")
            _ = await launchctl(["disable", "\(domain)/\(label)"])
            return await launchctl(["bootout", "\(domain)/\(label)"]).status == 0
        }
        return false
    }

    private static func launchctl(_ arguments: [String]) async -> (status: Int32, output: String) {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return (-1, "") }
            // concurrency-allow: a detached task off the main thread; launchctl prints a little and exits
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            // concurrency-allow: same detached task; the process has closed its output
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }.value
    }
}
