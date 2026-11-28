#if os(Linux)
import Glibc
import Foundation

/// One `/proc/<pid>/stat` reading: the Linux stand-in for `proc_bsdinfo`.
struct LinuxProcessSnapshot: Equatable {
    /// Parent process ID (`stat` field 4).
    let parentProcessID: Int32
    /// Owner, from the `/proc/<pid>` directory's uid.
    let userID: uid_t
    /// Start time in clock ticks since boot (`stat` field 22); with the PID it
    /// names one process generation, like `pbi_start_tvsec`/`tvusec` on Darwin.
    let startTicks: UInt64
    /// State `Z`: exited but not yet reaped.
    let isZombie: Bool
}

/// Linux `/proc` readers standing in for libproc and `sysctl(KERN_PROC*)`.
enum LinuxProcFS {
    /// Live PIDs owned by the current user: `proc_listpids(PROC_UID_ONLY, getuid())`.
    static func userProcessIDs(limit: Int = 8_192) -> [Int32] {
        guard let directory = opendir("/proc") else { return [] }
        defer { closedir(directory) }
        let uid = getuid()
        var pids: [Int32] = []
        while pids.count < limit, let entry = readdir(directory) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
            }
            guard let pid = Int32(name), pid > 0 else { continue }
            var status = stat()
            guard stat("/proc/\(pid)", &status) == 0, status.st_uid == uid else { continue }
            pids.append(pid)
        }
        return pids
    }

    /// Parent, owner, start time and zombie state, or nil when `pid` is gone.
    static func snapshot(_ pid: Int32) -> LinuxProcessSnapshot? {
        guard pid > 0 else { return nil }
        var directory = stat()
        guard stat("/proc/\(pid)", &directory) == 0,
              let bytes = read("/proc/\(pid)/stat", limit: 4_096),
              let close = bytes.lastIndex(of: UInt8(ascii: ")")) else { return nil }
        // Fields after the parenthesized command name start at field 3 (state).
        let fields = bytes[(close + 1)...].split(separator: UInt8(ascii: " ")).map {
            String(decoding: $0, as: UTF8.self)
        }
        guard fields.count > 19, let parent = Int32(fields[1]), let start = UInt64(fields[19]) else { return nil }
        return LinuxProcessSnapshot(
            parentProcessID: parent, userID: directory.st_uid,
            startTicks: start, isZombie: fields[0] == "Z"
        )
    }

    /// Start time in whole seconds since 1970, from the boot time and start ticks.
    static func startSeconds(_ pid: Int32) -> Int? {
        guard let snapshot = snapshot(pid), let boot = bootTime() else { return nil }
        let ticks = sysconf(Int32(_SC_CLK_TCK))
        guard ticks > 0 else { return nil }
        return boot + Int(snapshot.startTicks / UInt64(ticks))
    }

    /// The executable path: `proc_pidpath`, read from `/proc/<pid>/exe`.
    static func executablePath(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4_096)
        let length = readlink("/proc/\(pid)/exe", &buffer, buffer.count - 1)
        guard length > 0 else { return nil }
        var path = buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        // A replaced or unlinked executable reads back with this suffix.
        if path.hasSuffix(" (deleted)") { path.removeLast(" (deleted)".count) }
        return path
    }

    /// argv only (never the environment): `KERN_PROCARGS2`'s argument strings.
    static func arguments(_ pid: Int32) -> [String]? {
        guard let bytes = read("/proc/\(pid)/cmdline", limit: 1_048_576), !bytes.isEmpty else { return nil }
        var trimmed = bytes[...]
        if trimmed.last == 0 { trimmed = trimmed.dropLast() }
        return trimmed.split(separator: 0, omittingEmptySubsequences: false).map {
            String(decoding: $0, as: UTF8.self)
        }
    }

    /// Open descriptor numbers of `pid`: `PROC_PIDLISTFDS`.
    static func descriptors(_ pid: Int32, limit: Int = 4_096) -> [Int32] {
        guard let directory = opendir("/proc/\(pid)/fd") else { return [] }
        defer { closedir(directory) }
        var descriptors: [Int32] = []
        while descriptors.count < limit, let entry = readdir(directory) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
            }
            if let descriptor = Int32(name) { descriptors.append(descriptor) }
        }
        return descriptors
    }

    /// The device and inode `pid`'s descriptor refers to: `PROC_PIDFDVNODEINFO`'s `vi_stat`.
    static func descriptorFile(_ pid: Int32, _ descriptor: Int32) -> (device: UInt64, inode: UInt64)? {
        var status = stat()
        guard stat("/proc/\(pid)/fd/\(descriptor)", &status) == 0 else { return nil }
        return (UInt64(status.st_dev), UInt64(status.st_ino))
    }

    /// `pidfd_open(2)`: a descriptor that polls readable once `pid` exits, or -1.
    ///
    /// `syscall` is variadic and unavailable in Swift, and `<sys/pidfd.h>` is
    /// outside the Glibc module, so the glibc (2.36+) wrapper is looked up at
    /// run time. Older glibc or kernels before 5.3 get -1 and callers fall back.
    static func pidfdOpen(_ pid: Int32) -> Int32 {
        typealias PidfdOpen = @convention(c) (pid_t, UInt32) -> Int32
        guard let symbol = dlsym(nil, "pidfd_open") else { return -1 }
        return unsafeBitCast(symbol, to: PidfdOpen.self)(pid, 0)
    }

    private static func bootTime() -> Int? {
        guard let bytes = read("/proc/stat", limit: 1_048_576) else { return nil }
        for line in bytes.split(separator: UInt8(ascii: "\n")) where line.starts(with: Array("btime ".utf8)) {
            return Int(String(decoding: line.dropFirst(6), as: UTF8.self))
        }
        return nil
    }

    /// procfs reports size 0, so read until EOF instead of trusting `st_size`.
    private static func read(_ path: String, limit: Int) -> [UInt8]? {
        let descriptor = open(path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { Glibc.close(descriptor) }
        var bytes: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 4_096)
        while bytes.count < limit {
            let count = Glibc.read(descriptor, &chunk, chunk.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { return nil }
            if count == 0 { break }
            bytes += chunk.prefix(count)
        }
        return Array(bytes.prefix(limit))
    }
}
#endif
