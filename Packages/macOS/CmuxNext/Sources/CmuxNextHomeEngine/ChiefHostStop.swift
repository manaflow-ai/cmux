public import CmuxNextAgentPane
import Darwin
public import Foundation
import CmuxNextCompat

/// Quit, end sessions: this build's Chief home's brain host ends with the
/// other sessions (home-state-ownership.md section 3). Every build has its
/// own Chief home (`ChiefHome`), so a quit never stops another build's
/// Chief. A quit that keeps sessions keeps it running for the next launch.
public nonisolated enum ChiefHostStop {
    /// Sends SIGTERM to the host that holds the Chief home's lock; returns
    /// its pid, or nil when none runs. The pid comes from the lock's text and
    /// counts only while the lock is held and the process is an
    /// `optchat-chief`, so a stale text never names another process.
    @discardableResult
    @concurrent static func stop(home: ChiefHome, isChiefHost: @Sendable (pid_t) -> Bool = ChiefHostStop.isChiefHost) async -> pid_t? {
        guard let pid = runningHostPID(home: home, isChiefHost: isChiefHost), kill(pid, SIGTERM) == 0 else { return nil }
        return pid
    }

    /// An update: asks the host that holds the home's lock to hand off when idle (SIGUSR1). Its
    /// running turn goes on to its end, then it exits without ending its acpmux, and the restart
    /// (`ChiefBrainWatch` at a relaunch, `ChiefAcpmuxHeal` while the app runs) hands acpmux off and
    /// starts the next host, so an update never cuts a Chief turn. Only a host whose
    /// `state/host.handoff` names its own pid takes the signal (an older host would end at once on
    /// SIGUSR1); returns the pid it asked, nil when it asked none.
    @discardableResult
    static func askToHandOffWhenIdle(home: ChiefHome, isChiefHost: (pid_t) -> Bool = ChiefHostStop.isChiefHost,
                                     signal: (pid_t, Int32) -> Bool = { kill($0, $1) == 0 }) -> pid_t? {
        guard let pid = runningHostPID(home: home, isChiefHost: isChiefHost) else { return nil }
        let mark = home.root.appendingPathComponent("state/host.handoff")
        // concurrency-allow: a small local file read; callers run off the main actor
        guard let text = try? String(contentsOf: mark, encoding: .utf8),
              let named = text.split(separator: "\n").first.flatMap({ pid_t($0.trimmingCharacters(in: .whitespaces)) }),
              named == pid, signal(pid, SIGUSR1) else { return nil }
        return pid
    }

    /// The pid of the host that holds the home's lock: the pid in the lock's
    /// text while that process runs an `optchat-chief`. A host writes the
    /// text only after it holds the flock, so a live host named there holds
    /// it; a dead one's stale text names nothing. No lock probe: taking the
    /// flock for an instant can make a host that starts in that instant exit.
    public nonisolated static func runningHostPID(home: ChiefHome, isChiefHost: (pid_t) -> Bool = ChiefHostStop.isChiefHost) -> pid_t? {
        let lock = home.root.appendingPathComponent("state/host.lock")
        // concurrency-allow: a small local file read; callers run off the main actor or at a brain exit
        guard let text = try? String(contentsOf: lock, encoding: .utf8),
              let pid = text.split(separator: "\n").first.flatMap({ pid_t($0.trimmingCharacters(in: .whitespaces)) }),
              pid > 1, isChiefHost(pid) else { return nil }
        return pid
    }

    /// Quit, end sessions: the Chief home's host, then its acpmux daemon, so nothing of the Chief outlives the quit
    /// with ppid 1. The Chief owner ends through `ChiefConversationOwner`.
    /// What End Sessions keeps running in the Chief home's acpmux.
    static let endSessionsKeep: AcpmuxQuit.Keep = .nothing

    /// What End Sessions keeps running in the app's acpmux: nothing when the Chief runs there
    /// (``ChiefHome/usesAppAcpmux``), so its turn, compactor and subagents end with the person's
    /// agents; else the Home Chief's sessions, which its own daemon's end covers.
    public nonisolated static func appAcpmuxEndKeep(chiefUsesAppAcpmux: Bool) -> AcpmuxQuit.Keep {
        chiefUsesAppAcpmux ? .nothing : .chief
    }

    @concurrent public static func endChiefSessions(home: ChiefHome, bundledBin: URL?) async {
        _ = await stop(home: home)
        // On the app's own acpmux the Chief's sessions end with the app's (QuitAgents, keeping
        // nothing: ``appAcpmuxEndKeep(chiefUsesAppAcpmux:)``): ending
        // that daemon here would end the person's chats too.
        guard !home.usesAppAcpmux else { return }
        let environment = AcpmuxEnvironment.resolve(build: nil, bundledBinDirectory: bundledBin,
                                                    environment: ["ACPMUX_HOME": home.acpmuxHome.path])
        // The daemon exits (Quit Everything's own end); the Chief's sessions stay on disk.
        _ = await AcpmuxQuit.endAgents(environment, keep: endSessionsKeep)
    }

    /// Whether `pid` runs an `optchat-chief` executable.
    public static func isChiefHost(_ pid: pid_t) -> Bool {
        let path = executablePath(pid)
        return isChiefHost(path: path, processName: path == nil ? processName(pid) : nil)
    }

    /// The executable path of `pid` (`proc_pidpath`), nil when it fails: no such process, or
    /// its executable's file is gone.
    static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        return proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : nil
    }

    /// Whether a process with executable `path` (nil: `proc_pidpath` failed) and kernel process
    /// name `processName` is a Chief host. `proc_pidpath` fails once the executable's file is
    /// gone: an update replaced the bundle the host ran from. Such a host still holds the Chief
    /// home's lock and runs the old acpmux, so it must stay stoppable (the Chief acpmux handoff
    /// after an update); its process name is then the only fact left. Only a pid the held lock
    /// names reaches this check, and only one of this user's processes (`processName`).
    static func isChiefHost(path: String?, processName: String?) -> Bool {
        if let path { return path.hasSuffix("/" + HomeBrainHost.bundledChiefName) }
        return processName == HomeBrainHost.bundledChiefName
    }

    /// The kernel's name of `pid` (`pbi_name`, else `pbi_comm`) when it is one of this user's
    /// processes; nil otherwise.
    static func processName(_ pid: pid_t) -> String? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard blockingProcPidInfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_uid == getuid() else { return nil }
        let name = withUnsafeBytes(of: info.pbi_name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        if !name.isEmpty { return name }
        let command = withUnsafeBytes(of: info.pbi_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return command.isEmpty ? nil : command
    }
}
