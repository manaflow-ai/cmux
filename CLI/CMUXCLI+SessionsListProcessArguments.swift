import Darwin
import Foundation

extension CMUXCLI {
    struct SessionsListProcessIdentity {
        let executablePath: String?
        let arguments: [String]
        let startTime: TimeInterval
    }

    func sessionsListProcessIdentity(for pid: Int) -> SessionsListProcessIdentity? {
        guard pid > 0, pid <= Int(Int32.max) else { return nil }
        guard let startTime = sessionsListProcessStartTime(for: pid) else { return nil }
        return SessionsListProcessIdentity(
            executablePath: sessionsListProcessExecutablePath(for: pid),
            arguments: sessionsListProcessArguments(for: pid) ?? [],
            startTime: startTime
        )
    }

    func sessionsListProcessStartTimeMatchesRecord(
        _ processStartTime: TimeInterval,
        record: ClaudeHookSessionRecord
    ) -> Bool {
        // The hook update happens after the agent process starts. Allow a small
        // clock/sample tolerance, but reject PID reuse where the live process
        // started after the recorded hook update.
        processStartTime <= record.updatedAt + 5
    }

    private func sessionsListProcessStartTime(for pid: Int) -> TimeInterval? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, Int32(pid)]
        var process = kinfo_proc()
        var length = MemoryLayout<kinfo_proc>.stride
        let result = sysctl(&mib, u_int(mib.count), &process, &length, nil, 0)
        guard result == 0,
              length >= MemoryLayout<kinfo_proc>.stride,
              process.kp_proc.p_pid == pid_t(pid) else {
            return nil
        }
        let startTime = process.kp_proc.p_un.__p_starttime
        return TimeInterval(startTime.tv_sec) + (TimeInterval(startTime.tv_usec) / 1_000_000)
    }

    private func sessionsListProcessExecutablePath(for pid: Int) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = buffer.withUnsafeMutableBufferPointer { pointer in
            proc_pidpath(pid_t(pid), pointer.baseAddress, UInt32(pointer.count))
        }
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    private func sessionsListProcessArguments(for pid: Int) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, Int32(pid)]
        var size: size_t = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0,
              size > MemoryLayout<Int32>.size else {
            return nil
        }

        var buffer = [UInt8](repeating: 0, count: size)
        let success = buffer.withUnsafeMutableBytes { rawBuffer in
            sysctl(&mib, u_int(mib.count), rawBuffer.baseAddress, &size, nil, 0) == 0
        }
        guard success else { return nil }
        return sessionsListProcessArguments(from: Array(buffer.prefix(Int(size))))
    }

    private func sessionsListProcessArguments(from bytes: [UInt8]) -> [String]? {
        var argcRaw: Int32 = 0
        withUnsafeMutableBytes(of: &argcRaw) { rawBuffer in
            rawBuffer.copyBytes(from: bytes.prefix(MemoryLayout<Int32>.size))
        }
        let argc = Int(Int32(littleEndian: argcRaw))
        guard argc > 0 else { return nil }

        var index = MemoryLayout<Int32>.size
        sessionsListSkipString(in: bytes, index: &index)
        sessionsListSkipNulls(in: bytes, index: &index)

        var arguments: [String] = []
        for _ in 0..<argc {
            guard index < bytes.count else { return nil }
            let start = index
            sessionsListSkipString(in: bytes, index: &index)
            if start < index, let argument = String(bytes: bytes[start..<index], encoding: .utf8) {
                arguments.append(argument)
            }
            sessionsListSkipNulls(in: bytes, index: &index)
        }
        return arguments.isEmpty ? nil : arguments
    }

    private func sessionsListSkipString(in bytes: [UInt8], index: inout Int) {
        while index < bytes.count, bytes[index] != 0 { index += 1 }
    }

    private func sessionsListSkipNulls(in bytes: [UInt8], index: inout Int) {
        while index < bytes.count, bytes[index] == 0 { index += 1 }
    }
}
