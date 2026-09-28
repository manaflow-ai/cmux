import Darwin

extension TerminalSSHSessionDetector {
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
