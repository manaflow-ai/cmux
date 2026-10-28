import Darwin
import CmuxNextCompat

/// Whether `pid` names a process that runs: not gone and not a zombie.
///
/// `kill(pid, 0)` is not enough: a process that exited but was never reaped (a
/// zombie) still answers it, so a daemon that died under a parent that did not
/// wait for it looked alive and was never restarted. `proc_pidinfo` cannot read
/// a zombie either, so the state comes from the kernel's process table (`sysctl`).
nonisolated func agentPaneProcessIsRunning(_ pid: pid_t) -> Bool {
    guard pid > 0 else { return false }
    if kill(pid, 0) != 0 && errno == ESRCH { return false }
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    // The process exists (kill said so); a table read that fails says nothing more.
    // SAFETY: sysctl reads the mib.count names of `mib` and writes at most `size` bytes (one kinfo_proc) into `info`
    // and the size it wrote into `size`; all three are locals live for the call.
    guard unsafe blockingSysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return true }
    return info.kp_proc.p_stat != SZOMB
}
