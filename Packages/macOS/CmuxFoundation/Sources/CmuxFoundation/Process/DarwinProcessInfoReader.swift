import Darwin

/// Reads detailed topology, falling back to public kernel identity when libproc denies it.
struct DarwinProcessInfoReader {
    func readBSDInfo(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.stride
        if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size)) == size { return info }
        // libproc denies detailed records for other users, even though the
        // public process topology is readable. Keep those parent edges so an
        // unrelated protected process does not disable descendant accounting.
        // Its memory remains unavailable unless the resource APIs can read it.
        return fallbackBSDInfo(pid)
    }
    /// Reads only the public topology and generation fields needed by the index.
    func fallbackBSDInfo(_ pid: pid_t) -> proc_bsdinfo? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var process = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, u_int(mib.count), &process, &size, nil, 0) == 0,
              size == MemoryLayout<kinfo_proc>.stride,
              process.kp_proc.p_pid == pid else { return nil }
        let start = process.kp_proc.p_un.__p_starttime
        guard start.tv_sec >= 0, start.tv_usec >= 0 else { return nil }
        var info = proc_bsdinfo()
        info.pbi_pid = UInt32(pid)
        info.pbi_ppid = UInt32(max(0, process.kp_eproc.e_ppid))
        info.pbi_pgid = UInt32(max(0, process.kp_eproc.e_pgid))
        info.e_tpgid = UInt32(max(0, process.kp_eproc.e_tpgid))
        info.e_tdev = UInt32(bitPattern: process.kp_eproc.e_tdev)
        info.pbi_start_tvsec = UInt64(start.tv_sec)
        info.pbi_start_tvusec = UInt64(start.tv_usec)
        withUnsafeMutableBytes(of: &info.pbi_comm) { destination in
            withUnsafeBytes(of: process.kp_proc.p_comm) { source in
                destination.copyBytes(from: source.prefix(destination.count - 1))
            }
        }
        return info
    }
}
