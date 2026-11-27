import Darwin

extension TerminalSSHSessionDetector {
    /// Whether the TTY's foreground job contains an `ssh` or `et` process.
    /// `processGroupID` is the PTY's foreground process group (`tcgetpgrp`).
    /// Cheap enough for the main actor; see
    /// ``processSnapshots(inProcessGroup:ttyName:)`` for the complexity contract.
    ///
    /// `nil` means the group could not be read, which is not the same answer as
    /// `false`. Only `false` is a confident "no remote shell here", so a caller
    /// may skip the async lookup on `false` and must keep it on `nil`.
    static func foregroundJobHasRemoteShell(processGroupID: Int32, ttyName: String) -> Bool? {
        let normalizedTTY = normalizeTTYName(ttyName)
        guard !normalizedTTY.isEmpty else { return nil }
        let snapshots = processSnapshots(inProcessGroup: processGroupID, ttyName: normalizedTTY)
        // A live foreground group has at least one member on this TTY, since
        // the kernel just named it as the group reading from the terminal. An
        // empty result means the TTY name did not resolve, `proc_listpids`
        // failed, or the job exited between the two syscalls. None of those is
        // evidence that the job is local.
        guard !snapshots.isEmpty else { return nil }
        return snapshots.contains { isForegroundRemoteShellProcess($0, ttyName: normalizedTTY) }
    }

    static func processSnapshots(forTTY ttyName: String) -> [ProcessSnapshot] {
        guard let ttyDevice = CmuxTopProcessSnapshot.deviceIdentifier(forTTYName: ttyName),
              ttyDevice <= Int64(UInt32.max) else {
            return []
        }

        var capacity = 64
        while capacity <= 4096 {
            var pids = [pid_t](repeating: 0, count: capacity)
            let byteCount = pids.withUnsafeMutableBytes { rawBuffer in
                proc_listpids(
                    UInt32(PROC_TTY_ONLY),
                    UInt32(ttyDevice),
                    rawBuffer.baseAddress,
                    Int32(rawBuffer.count)
                )
            }
            guard byteCount > 0 else { return [] }
            let count = min(Int(byteCount) / MemoryLayout<pid_t>.stride, pids.count)
            if byteCount < Int32(pids.count * MemoryLayout<pid_t>.stride) {
                return pids.prefix(count).compactMap { pid in
                    processSnapshot(
                        for: pid,
                        ttyName: ttyName,
                        ttyDevice: UInt32(ttyDevice)
                    )
                }
            }
            if capacity == 4096 {
                return pids.compactMap { pid in
                    processSnapshot(
                        for: pid,
                        ttyName: ttyName,
                        ttyDevice: UInt32(ttyDevice)
                    )
                }
            }
            capacity *= 2
        }
        return []
    }

    /// Lists one process group, keeping the members whose controlling
    /// terminal is `ttyName`.
    ///
    /// Cost contract: this runs on the main actor for every terminal drop and
    /// paste. The kernel filters the process list by group in one call
    /// (sub-millisecond even with thousands of processes), and the app then
    /// makes one `proc_pidinfo` call per group member, usually one to three.
    /// Do not replace it with work per process on the TTY or the machine
    /// (`/bin/ps`, or `proc_pidinfo` over every PID): at load averages above
    /// 200 that froze each drop for seconds.
    static func processSnapshots(inProcessGroup processGroupID: Int32, ttyName: String) -> [ProcessSnapshot] {
        guard processGroupID > 0,
              let ttyDevice = CmuxTopProcessSnapshot.deviceIdentifier(forTTYName: ttyName),
              ttyDevice <= Int64(UInt32.max) else {
            return []
        }

        var capacity = 16
        while capacity <= 4096 {
            var pids = [pid_t](repeating: 0, count: capacity)
            let byteCount = pids.withUnsafeMutableBytes { rawBuffer in
                proc_listpids(
                    UInt32(PROC_PGRP_ONLY),
                    UInt32(bitPattern: processGroupID),
                    rawBuffer.baseAddress,
                    Int32(rawBuffer.count)
                )
            }
            guard byteCount > 0 else { return [] }
            let count = min(Int(byteCount) / MemoryLayout<pid_t>.stride, pids.count)
            if count < pids.count {
                return pids.prefix(count).compactMap { pid in
                    processSnapshot(
                        for: pid,
                        ttyName: ttyName,
                        ttyDevice: UInt32(ttyDevice)
                    )
                }
            }
            // A full final buffer may have omitted a group member. Treat that
            // incomplete snapshot as unknown so the caller keeps the bounded
            // asynchronous detector instead of assuming the job is local.
            capacity *= 4
        }
        return []
    }

    private static func processSnapshot(
        for pid: pid_t,
        ttyName: String,
        ttyDevice: UInt32
    ) -> ProcessSnapshot? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let expectedSize = MemoryLayout<proc_bsdinfo>.stride
        let size = proc_pidinfo(
            pid,
            PROC_PIDTBSDINFO,
            0,
            &info,
            Int32(expectedSize)
        )
        guard size == expectedSize,
              info.e_tdev == ttyDevice,
              info.e_tpgid > 0,
              info.pbi_pgid > 0 else {
            return nil
        }
        return ProcessSnapshot(
            pid: pid,
            pgid: Int32(info.pbi_pgid),
            tpgid: Int32(info.e_tpgid),
            tty: ttyName,
            executableName: CmuxTopProcessSnapshot
                .fixedString(info.pbi_comm)
                .lowercased()
        )
    }
}
