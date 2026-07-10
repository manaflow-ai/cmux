internal import Darwin
internal import Foundation

/// Captures orphan-candidate SSH processes with libproc and `KERN_PROCARGS2`.
struct NativeRemoteOrphanProcessSnapshotCapturer: RemoteOrphanProcessSnapshotCapturing {
    private static let pidPathBufferSize = 4096

    func capture() async -> [RemoteOrphanProcessSnapshot] {
        await Task.detached(priority: .utility) {
            Self.captureSynchronously()
        }.value
    }

    static func isStillSameProcess(_ snapshot: RemoteOrphanProcessSnapshot) -> Bool {
        guard let expectedIdentity = snapshot.identity else {
            return true
        }
        guard let current = bsdInfo(for: snapshot.pid) else {
            return false
        }
        return Int(current.pbi_ppid) == snapshot.parentPID
            && identity(from: current) == expectedIdentity
    }

    private static func captureSynchronously() -> [RemoteOrphanProcessSnapshot] {
        launchdChildPIDs().compactMap { pid in
            guard let bsdInfo = bsdInfo(for: pid),
                  bsdInfo.pbi_ppid == 1,
                  isSSHProcess(pid: pid, bsdInfo: bsdInfo),
                  let arguments = arguments(for: pid),
                  !arguments.isEmpty else {
                return nil
            }
            return RemoteOrphanProcessSnapshot(
                pid: pid,
                parentPID: Int(bsdInfo.pbi_ppid),
                command: arguments.joined(separator: " "),
                identity: identity(from: bsdInfo)
            )
        }
    }

    private static func bsdInfo(for pid: Int) -> proc_bsdinfo? {
        guard pid > 0, pid <= Int(Int32.max) else { return nil }
        var info = proc_bsdinfo()
        let expectedSize = MemoryLayout<proc_bsdinfo>.stride
        let size = proc_pidinfo(pid_t(pid), PROC_PIDTBSDINFO, 0, &info, Int32(expectedSize))
        return size == expectedSize ? info : nil
    }

    private static func identity(from info: proc_bsdinfo) -> RemoteOrphanProcessSnapshot.Identity {
        RemoteOrphanProcessSnapshot.Identity(
            startSeconds: UInt64(info.pbi_start_tvsec),
            startMicroseconds: UInt64(info.pbi_start_tvusec)
        )
    }

    /// Orphaned transports are direct launchd children, so enumerate that
    /// bounded candidate set instead of issuing `proc_pidinfo` for every PID.
    private static func launchdChildPIDs() -> [Int] {
        let initialCount = Int(proc_listchildpids(1, nil, 0))
        guard initialCount > 0 else { return [] }
        let pidStride = MemoryLayout<pid_t>.stride
        var capacity = initialCount + 32
        var lastPIDs: [Int] = []
        for _ in 0..<3 {
            var pids = Array(repeating: pid_t(), count: capacity)
            let returnedCount = pids.withUnsafeMutableBufferPointer { buffer in
                proc_listchildpids(1, buffer.baseAddress, Int32(buffer.count * pidStride))
            }
            guard returnedCount >= 0 else { return lastPIDs }
            let count = min(Int(returnedCount), pids.count)
            lastPIDs = pids.prefix(count).compactMap { $0 > 0 ? Int($0) : nil }
            if Int(returnedCount) < pids.count {
                return lastPIDs
            }
            capacity = max(capacity * 2, Int(returnedCount) + 32)
        }
        return lastPIDs
    }

    private static func isSSHProcess(pid: Int, bsdInfo: proc_bsdinfo) -> Bool {
        if fixedString(bsdInfo.pbi_comm) == "ssh" {
            return true
        }
        var pathBuffer = [CChar](repeating: 0, count: pidPathBufferSize)
        let length = proc_pidpath(pid_t(pid), &pathBuffer, UInt32(pathBuffer.count))
        guard length > 0 else { return false }
        let path = String(
            decoding: pathBuffer.prefix(Int(length)).map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
        return URL(fileURLWithPath: path).lastPathComponent == "ssh"
    }

    private static func arguments(for pid: Int) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, Int32(pid)]
        var size: size_t = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0,
              size > MemoryLayout<Int32>.size else {
            return nil
        }
        var bytes = [UInt8](repeating: 0, count: size)
        let success = bytes.withUnsafeMutableBytes { buffer in
            sysctl(&mib, u_int(mib.count), buffer.baseAddress, &size, nil, 0) == 0
        }
        guard success else { return nil }
        return parseArguments(Array(bytes.prefix(Int(size))))
    }

    private static func parseArguments(_ bytes: [UInt8]) -> [String]? {
        guard bytes.count > MemoryLayout<Int32>.size else { return nil }
        var argumentCountRaw: Int32 = 0
        withUnsafeMutableBytes(of: &argumentCountRaw) { buffer in
            buffer.copyBytes(from: bytes.prefix(MemoryLayout<Int32>.size))
        }
        let argumentCount = Int(Int32(littleEndian: argumentCountRaw))
        guard argumentCount > 0 else { return nil }

        var index = MemoryLayout<Int32>.size
        skipString(in: bytes, index: &index)
        skipNulls(in: bytes, index: &index)
        var arguments: [String] = []
        arguments.reserveCapacity(argumentCount)
        for _ in 0..<argumentCount {
            guard index < bytes.count else { return nil }
            let start = index
            skipString(in: bytes, index: &index)
            guard let argument = String(bytes: bytes[start..<index], encoding: .utf8) else {
                return nil
            }
            arguments.append(argument)
            if index < bytes.count, bytes[index] == 0 {
                index += 1
            }
        }
        return arguments
    }

    private static func skipString(in bytes: [UInt8], index: inout Int) {
        while index < bytes.count, bytes[index] != 0 {
            index += 1
        }
    }

    private static func skipNulls(in bytes: [UInt8], index: inout Int) {
        while index < bytes.count, bytes[index] == 0 {
            index += 1
        }
    }

    private static func fixedString<T>(_ value: T) -> String {
        withUnsafeBytes(of: value) { buffer in
            let end = buffer.firstIndex(of: 0) ?? buffer.endIndex
            return String(decoding: buffer[..<end], as: UTF8.self)
        }
    }
}
