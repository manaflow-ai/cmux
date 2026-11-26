import Darwin
import Foundation

struct SystemSudoProcessInspector: SudoProcessInspecting {
    func identity(for processIdentifier: Int32) -> SudoProcessIdentity? {
        guard processIdentifier > 0 else { return nil }

        var bsdInfo = proc_bsdinfo()
        let expectedSize = MemoryLayout<proc_bsdinfo>.stride
        let size = proc_pidinfo(
            processIdentifier,
            PROC_PIDTBSDINFO,
            0,
            &bsdInfo,
            Int32(expectedSize)
        )
        if size == expectedSize, bsdInfo.pbi_status != UInt32(SZOMB) {
            return SudoProcessIdentity(
                processIdentifier: processIdentifier,
                startSeconds: Int64(bsdInfo.pbi_start_tvsec),
                startMicroseconds: Int32(bsdInfo.pbi_start_tvusec)
            )
        }

        guard let process = processTableEntry(for: processIdentifier), !process.isZombie else {
            return nil
        }
        return SudoProcessIdentity(
            processIdentifier: processIdentifier,
            startSeconds: process.startSeconds,
            startMicroseconds: process.startMicroseconds
        )
    }

    func executableURL(for processIdentifier: Int32) -> URL? {
        var buffer = [CChar](repeating: 0, count: 4_096)
        let length = buffer.withUnsafeMutableBufferPointer { pointer in
            proc_pidpath(processIdentifier, pointer.baseAddress, UInt32(pointer.count))
        }
        guard length > 0,
              let path = String(
                  bytes: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) },
                  encoding: .utf8
              ) else {
            return nil
        }
        return URL(fileURLWithPath: path)
            .resolvingSymlinksInPath()
            .standardizedFileURL
    }

    func arguments(for processIdentifier: Int32) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, processIdentifier]
        var size: size_t = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0,
              size > MemoryLayout<Int32>.size else {
            return nil
        }

        var bytes = [UInt8](repeating: 0, count: size)
        let readSucceeded = bytes.withUnsafeMutableBytes { buffer in
            sysctl(&mib, UInt32(mib.count), buffer.baseAddress, &size, nil, 0) == 0
        }
        guard readSucceeded else { return nil }
        return Self.decodeArguments(Array(bytes.prefix(Int(size))))
    }

    func directChildProcessIdentifiers(of processIdentifier: Int32) -> [Int32] {
        guard processIdentifier > 0 else { return [] }
        let stride = MemoryLayout<pid_t>.stride
        var capacity = 16
        var lastResult: [Int32] = []
        for _ in 0..<4 {
            var processIdentifiers = [pid_t](repeating: 0, count: capacity)
            errno = 0
            let returnedCount = processIdentifiers.withUnsafeMutableBufferPointer { buffer in
                proc_listchildpids(
                    processIdentifier,
                    buffer.baseAddress,
                    Int32(buffer.count * stride)
                )
            }
            guard returnedCount >= 0 else { return lastResult }
            guard returnedCount != 0 || errno == 0 else { return lastResult }
            let count = min(processIdentifiers.count, Int(returnedCount))
            lastResult = processIdentifiers.prefix(count).filter { $0 > 1 }
            if Int(returnedCount) < processIdentifiers.count {
                return lastResult
            }
            capacity = max(processIdentifiers.count * 2, Int(returnedCount) + 16)
        }
        return lastResult
    }

    func processIdentifiers(inProcessGroup processGroupIdentifier: Int32) -> [Int32]? {
        guard processGroupIdentifier > 1 else { return [] }
        let stride = MemoryLayout<pid_t>.stride
        var capacity = 16
        var lastResult: [Int32] = []
        let maximumCapacity = 16 * 1_024
        while capacity <= maximumCapacity {
            var processIdentifiers = [pid_t](repeating: 0, count: capacity)
            errno = 0
            let returnedCount = processIdentifiers.withUnsafeMutableBufferPointer { buffer in
                proc_listpgrppids(
                    processGroupIdentifier,
                    buffer.baseAddress,
                    Int32(buffer.count * stride)
                )
            }
            guard returnedCount >= 0 else { return nil }
            guard returnedCount != 0 || errno == 0 else { return nil }
            let count = min(processIdentifiers.count, Int(returnedCount))
            lastResult = processIdentifiers.prefix(count).filter { $0 > 1 }
            if Int(returnedCount) < processIdentifiers.count {
                return lastResult
            }
            capacity = max(processIdentifiers.count * 2, Int(returnedCount) + 16)
        }
        return nil
    }

    func processGroupIdentifier(for processIdentifier: Int32) -> Int32? {
        let group = getpgid(processIdentifier)
        return group > 1 ? group : nil
    }

    func allProcessIdentifiers() -> [Int32] {
        let estimatedCount = proc_listallpids(nil, 0)
        guard estimatedCount > 0 else { return [] }
        var capacity = Int(estimatedCount) + 64
        var lastResult: [Int32] = []
        for _ in 0..<4 {
            var processIdentifiers = [pid_t](repeating: 0, count: capacity)
            let count = processIdentifiers.withUnsafeMutableBufferPointer { buffer in
                proc_listallpids(
                    buffer.baseAddress,
                    Int32(buffer.count * MemoryLayout<pid_t>.stride)
                )
            }
            guard count > 0 else { return lastResult }
            lastResult = processIdentifiers.prefix(Int(count)).filter { $0 > 1 }
            if Int(count) < processIdentifiers.count {
                return lastResult
            }
            capacity = processIdentifiers.count * 2
        }
        return lastResult
    }

    func isRunning(_ identity: SudoProcessIdentity) -> Bool {
        self.identity(for: identity.processIdentifier) == identity
    }

    private func processTableEntry(
        for processIdentifier: Int32
    ) -> (startSeconds: Int64, startMicroseconds: Int32, isZombie: Bool)? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, processIdentifier]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0,
              size > 0,
              info.kp_proc.p_pid == processIdentifier else {
            return nil
        }
        let start = info.kp_proc.p_un.__p_starttime
        return (
            Int64(start.tv_sec),
            Int32(start.tv_usec),
            info.kp_proc.p_stat == Int8(SZOMB)
        )
    }

    private static func decodeArguments(_ bytes: [UInt8]) -> [String]? {
        guard bytes.count > MemoryLayout<Int32>.size else { return nil }
        var argumentCountRaw: Int32 = 0
        withUnsafeMutableBytes(of: &argumentCountRaw) { destination in
            destination.copyBytes(from: bytes.prefix(MemoryLayout<Int32>.size))
        }
        let argumentCount = Int(Int32(littleEndian: argumentCountRaw))
        guard argumentCount > 0 else { return nil }

        var index = MemoryLayout<Int32>.size
        skipString(in: bytes, index: &index)
        skipNulls(in: bytes, index: &index)

        var arguments: [String] = []
        for _ in 0..<argumentCount {
            guard index < bytes.count else { return nil }
            let start = index
            skipString(in: bytes, index: &index)
            guard let argument = String(bytes: bytes[start..<index], encoding: .utf8) else {
                return nil
            }
            arguments.append(argument)
            if index < bytes.count, bytes[index] == 0 { index += 1 }
        }
        return arguments
    }

    private static func skipString(in bytes: [UInt8], index: inout Int) {
        while index < bytes.count, bytes[index] != 0 { index += 1 }
    }

    private static func skipNulls(in bytes: [UInt8], index: inout Int) {
        while index < bytes.count, bytes[index] == 0 { index += 1 }
    }
}
