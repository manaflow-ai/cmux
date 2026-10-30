import Darwin
import Foundation

private let agentHookWrapperProcessNames: Set<String> = [
    "sh",
    "bash",
    "zsh",
    "env"
]


/// Hook process ancestry and kernel-backed Kiro executable identity.
extension CMUXCLI {
    // MARK: - Agent PID inference

    func agentPIDFromHookEnvironment(agentName: String, env: [String: String]) -> Int? {
        let envKey = Self.agentHookPIDEnvironmentVariable(agentName: agentName)
        guard let raw = env[envKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
              let pid = Int(raw),
              pid > 0 else {
            return nil
        }
        return pid
    }

    func inferredAgentPID() -> Int? {
        var candidate = getppid()
        var remainingWrapperSkips = 8

        while candidate > 1, remainingWrapperSkips > 0 {
            guard let processName = processName(for: candidate) else { break }
            if !agentHookWrapperProcessNames.contains(processName) {
                break
            }
            let next = parentPID(of: candidate)
            guard next > 1, next != candidate else { break }
            candidate = next
            remainingWrapperSkips -= 1
        }

        return candidate > 1 ? Int(candidate) : nil
    }

    /// On Kiro CLI V3 the hook shell's parent is not the `kiro-cli` process the user started.
    /// Restore trusts only `kiro-cli` as Kiro, and its argv is the user's launch command, so
    /// resolve the hook's agent pid to the `kiro-cli` process this hook runs under, if any.
    func kiroCLIAncestorPID() -> Int? {
        kiroCLIPID(above: getppid()).map(Int.init)
    }

    /// True when the hook runs under a `kiro-cli chat --no-interactive` run, or under a `kiro-cli`
    /// started from inside another one. Neither should take the pane's agent messages.
    func kiroHookIsHeadlessOrNested() -> Bool {
        guard let kiroCLI = kiroCLIPID(above: getppid()),
              let arguments = processArguments(for: kiroCLI) else { return true }
        if arguments.contains("--no-interactive") { return true }
        let parent = parentPID(of: kiroCLI)
        return parent > 1 && kiroCLIPID(above: parent) != nil
    }

    /// Matches the kernel's process name (`proc_name`), which argv cannot change, and never spawns
    /// `/bin/ps`.
    private func kiroCLIPID(above start: pid_t) -> pid_t? {
        var candidate = start
        for _ in 0..<8 {
            // `proc_name` is a useful fast filter, but it is derived from the
            // process name and can be changed by a launcher. Accept Kiro only
            // when the kernel-reported executable path agrees as well.
            if libprocProcessName(for: candidate) == "kiro-cli",
               let executablePath = libprocExecutablePath(for: candidate),
               URL(fileURLWithPath: executablePath).lastPathComponent.lowercased() == "kiro-cli" {
                return candidate
            }
            let next = parentPID(of: candidate)
            guard next > 1, next != candidate else { return nil }
            candidate = next
        }
        return nil
    }

    /// `/bin/ps` is setuid root, and sandboxes that deny setuid binaries make it fail to start.
    /// `proc_name` still answers there, which keeps the agent visible to its own hooks.
    func libprocProcessName(for pid: pid_t) -> String? {
        var name = [CChar](repeating: 0, count: 2 * Int(MAXCOMLEN) + 1)
        guard proc_name(pid, &name, UInt32(name.count)) > 0 else { return nil }
        return String(cString: name).lowercased()
    }

    /// Returns the executable path reported by the kernel for a live process.
    /// This is the identity check used when a Kiro hook walks its ancestry;
    /// argv[0] is caller-controlled and is never used for that decision.
    private func libprocExecutablePath(for pid: pid_t) -> String? {
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
        let value = String(cString: path).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
