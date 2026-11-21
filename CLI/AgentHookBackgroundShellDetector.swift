import Darwin
import Foundation

/// Detects a live shell that an agent owns outside the current hook's process branch.
struct AgentHookBackgroundShellDetector {
    struct ProcessSnapshot: Equatable {
        let processID: pid_t
        let parentProcessID: pid_t
        let name: String
    }

    private static let shellNames: Set<String> = [
        "sh", "bash", "zsh", "fish", "dash", "ksh", "mksh", "tcsh", "csh", "nu", "pwsh", "elvish", "xonsh",
    ]

    let processes: [ProcessSnapshot]

    func hasLiveShellChild(agentProcessID: pid_t, hookProcessID: pid_t = getpid()) -> Bool {
        guard agentProcessID > 1 else { return false }
        let excludedHookChild = directChild(
            of: agentProcessID,
            containing: hookProcessID
        )
        return processes.contains { process in
            process.parentProcessID == agentProcessID
                && process.processID != excludedHookChild
                && Self.isShell(process.name)
        }
    }

    static func capture() -> AgentHookBackgroundShellDetector? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var byteCount = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &byteCount, nil, 0) == 0,
              byteCount >= MemoryLayout<kinfo_proc>.stride else {
            return nil
        }

        var entries = [kinfo_proc](
            repeating: kinfo_proc(),
            count: byteCount / MemoryLayout<kinfo_proc>.stride
        )
        let status = entries.withUnsafeMutableBytes { buffer in
            sysctl(&mib, UInt32(mib.count), buffer.baseAddress, &byteCount, nil, 0)
        }
        guard status == 0 else { return nil }

        let count = min(entries.count, byteCount / MemoryLayout<kinfo_proc>.stride)
        return AgentHookBackgroundShellDetector(
            processes: entries.prefix(count).compactMap { entry in
                guard entry.kp_proc.p_pid > 1,
                      entry.kp_proc.p_stat != Int8(SZOMB) else {
                    return nil
                }
                var command = entry.kp_proc.p_comm
                let commandCapacity = MemoryLayout.size(ofValue: command)
                let name = withUnsafePointer(to: &command) { pointer in
                    pointer.withMemoryRebound(to: CChar.self, capacity: commandCapacity) {
                        String(cString: $0)
                    }
                }
                return ProcessSnapshot(
                    processID: entry.kp_proc.p_pid,
                    parentProcessID: entry.kp_eproc.e_ppid,
                    name: name
                )
            }
        )
    }

    private func directChild(of ancestor: pid_t, containing descendant: pid_t) -> pid_t? {
        let parentByProcessID = Dictionary(
            uniqueKeysWithValues: processes.map { ($0.processID, $0.parentProcessID) }
        )
        var candidate = descendant
        var remainingAncestors = 64
        while candidate > 1, remainingAncestors > 0, let parent = parentByProcessID[candidate] {
            if parent == ancestor {
                return candidate
            }
            guard parent != candidate else { return nil }
            candidate = parent
            remainingAncestors -= 1
        }
        return nil
    }

    private static func isShell(_ name: String) -> Bool {
        var basename = URL(fileURLWithPath: name).lastPathComponent.lowercased()
        if basename.hasPrefix("-") {
            basename.removeFirst()
        }
        return shellNames.contains(basename)
    }
}
