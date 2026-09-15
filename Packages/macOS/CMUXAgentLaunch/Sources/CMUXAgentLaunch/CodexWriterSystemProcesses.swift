import Darwin
import Foundation

/// Reads kernel snapshots once per diagnostic batch, without launching ps or lsof.
struct CodexWriterSystemProcesses: CodexWriterProcessInspecting {
    private let temporaryDirectory: URL

    init(temporaryDirectory: URL) {
        self.temporaryDirectory = temporaryDirectory
    }

    func snapshot(locks: [CodexWriterLockInspection]) -> CodexWriterProcessSnapshot {
        var result = CodexWriterProcessSnapshot()
        var needsPathVerification = false
        let targets = Set(locks.compactMap(CodexWriterFileIdentity.init))
        guard !targets.isEmpty else { return result }
        guard let identifiers = processIdentifiers() else {
            result.isComplete = false
            return result
        }
        for pid in identifiers where pid != getpid() {
            guard let info = information(pid) else {
                if errno != ESRCH { result.isComplete = false }
                continue
            }
            guard info.pbi_status != SZOMB else { continue }
            guard let descriptors = fileDescriptors(pid) else {
                if information(pid) != nil { result.isComplete = false }
                continue
            }
            var heldFiles = Set<CodexWriterFileIdentity>()
            for descriptor in descriptors where descriptor.proc_fdtype == PROX_FDTYPE_VNODE {
                var vnode = vnode_fdinfo()
                let size = Int32(MemoryLayout<vnode_fdinfo>.stride)
                guard proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDVNODEINFO, &vnode, size) == size else {
                    if errno != EBADF && errno != ESRCH { needsPathVerification = true }
                    continue
                }
                let identity = CodexWriterFileIdentity(
                    device: vnode.pvi.vi_stat.vst_dev,
                    inode: vnode.pvi.vi_stat.vst_ino
                )
                if targets.contains(identity) { heldFiles.insert(identity) }
            }
            let executable = executablePath(pid)
            let basename = executable.map { URL(fileURLWithPath: $0).lastPathComponent }
            guard !heldFiles.isEmpty || basename == "cmux" else { continue }
            guard let arguments = arguments(pid), let version = pidVersion(pid),
                  let current = information(pid),
                  current.pbi_start_tvsec == info.pbi_start_tvsec,
                  current.pbi_start_tvusec == info.pbi_start_tvusec else {
                result.isComplete = false
                continue
            }
            let preliminary = CodexWriterProcessEvidence(
                pid: pid, parentPID: Int32(current.pbi_ppid), command: arguments.joined(separator: " "),
                executablePath: executable, arguments: arguments
            )
            if let port = preliminary.watcherAppServerPort { result.watchedPorts.insert(port) }
            let port = preliminary.appServerPort
            let holder = CodexWriterProcessEvidence(
                pid: pid,
                parentPID: Int32(current.pbi_ppid),
                command: arguments.joined(separator: " "),
                startTime: "\(info.pbi_start_tvsec):\(info.pbi_start_tvusec)",
                executablePath: executable,
                arguments: arguments,
                pidVersion: version,
                isPrivateCmuxServer: port.map { hasCmuxLog(pid, port: $0) } ?? false,
                hasConnectedClients: port.map { !hasIdleListener(pid, port: $0, descriptors: descriptors) } ?? true,
                hasControllingTerminal: current.pbi_flags & UInt32(PROC_FLAG_CONTROLT) != 0
            )
            guard pidVersion(pid) == version else {
                result.isComplete = false
                continue
            }
            for identity in heldFiles { result.holders[identity, default: []].append(holder) }
        }
        if needsPathVerification {
            for lock in locks {
                guard let identity = CodexWriterFileIdentity(lock: lock),
                      let owners = ownersReferencing(lock.lockPath),
                      owners == Set((result.holders[identity] ?? []).map(\.pid)) else {
                    result.isComplete = false
                    continue
                }
            }
        }
        return result
    }

    /// Protected unrelated vnodes can deny metadata reads. Verify the exact accessible
    /// lock path separately; an additional or unreadable holder still disables recovery.
    private func ownersReferencing(_ path: String) -> Set<Int32>? {
        let required = proc_listpidspath(UInt32(PROC_UID_ONLY), geteuid(), path, 0, nil, 0)
        guard required > 0, required < 4_000_000 else { return nil }
        var identifiers = [Int32](repeating: 0, count: Int(required) / 4 + 1024)
        let capacity = Int32(identifiers.count * 4)
        let count = identifiers.withUnsafeMutableBytes {
            proc_listpidspath(UInt32(PROC_UID_ONLY), geteuid(), path, 0, $0.baseAddress, capacity)
        }
        guard count > 0, count < capacity, count % 4 == 0 else { return nil }
        return Set(identifiers.prefix(Int(count) / 4).filter { $0 > 0 && $0 != getpid() })
    }

    /// Signals the captured process generation, never a PID that has since been reused.
    func terminate(_ holder: CodexWriterProcessEvidence) -> Bool {
        guard holder.pid > 1, let version = holder.pidVersion else { return false }
        var token = audit_token_t(val: (UInt32.max, UInt32.max, UInt32.max, UInt32.max,
                                        UInt32.max, UInt32(holder.pid), UInt32.max, version))
        return proc_signal_with_audittoken(&token, SIGTERM) == 0
    }

    private func processIdentifiers() -> [Int32]? {
        let required = proc_listpids(UInt32(PROC_UID_ONLY), geteuid(), nil, 0)
        guard required > 0, required < 4_000_000 else { return nil }
        var identifiers = [Int32](repeating: 0, count: Int(required) / 4 + 1024)
        let capacity = Int32(identifiers.count * 4)
        let count = identifiers.withUnsafeMutableBytes {
            proc_listpids(UInt32(PROC_UID_ONLY), geteuid(), $0.baseAddress, capacity)
        }
        guard count >= 0, count < capacity, count % 4 == 0 else { return nil }
        return identifiers.prefix(Int(count) / 4).filter { $0 > 0 }
    }

    private func information(_ pid: Int32) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info
    }

    func fileDescriptors(_ pid: Int32) -> [proc_fdinfo]? {
        let required = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard required > 0, required < 16_000_000 else { return nil }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(required) / stride + 128)
        let capacity = Int32(descriptors.count * stride)
        let count = descriptors.withUnsafeMutableBytes {
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, capacity)
        }
        guard count > 0, count < capacity, Int(count) % stride == 0 else { return nil }
        return Array(descriptors.prefix(Int(count) / stride))
    }

    private func executablePath(_ pid: Int32) -> String? {
        var bytes = [UInt8](repeating: 0, count: 4096)
        let count = bytes.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
        guard count > 0 else { return nil }
        return String(bytes: bytes.prefix { $0 != 0 }, encoding: .utf8)
    }

    /// PROC_PIDUNIQIDENTIFIERINFO has a 16-byte UUID, two UInt64 IDs, then p_idversion.
    private func pidVersion(_ pid: Int32) -> UInt32? {
        var words = [UInt32](repeating: 0, count: 14)
        let count = words.withUnsafeMutableBytes { proc_pidinfo(pid, 17, 0, $0.baseAddress, Int32($0.count)) }
        guard count == 56 else { return nil }
        return words[8]
    }

    private func arguments(_ pid: Int32) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0,
              size > 4, size <= 4_000_000 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        let status = bytes.withUnsafeMutableBytes { sysctl(&mib, UInt32(mib.count), $0.baseAddress, &size, nil, 0) }
        guard status == 0 else { return nil }
        return CodexWriterProcessArguments().decode(Array(bytes.prefix(size)))
    }

    private func hasCmuxLog(_ pid: Int32, port: Int) -> Bool {
        var output = vnode_fdinfo()
        var error = vnode_fdinfo()
        let outputSize = Int32(MemoryLayout<vnode_fdinfo>.stride)
        let errorSize = Int32(MemoryLayout<vnode_fdinfo>.stride)
        guard proc_pidfdinfo(pid, STDOUT_FILENO, PROC_PIDFDVNODEINFO, &output, outputSize) == outputSize,
              proc_pidfdinfo(pid, STDERR_FILENO, PROC_PIDFDVNODEINFO, &error, errorSize) == errorSize,
              output.pvi.vi_stat.vst_ino == error.pvi.vi_stat.vst_ino,
              output.pvi.vi_stat.vst_dev == error.pvi.vi_stat.vst_dev,
              error.pvi.vi_stat.vst_uid == geteuid() else { return false }
        let expected = temporaryDirectory
            .appendingPathComponent("cmux-codex-teams-\(port)-app-server.log").path
        var file = stat()
        guard lstat(expected, &file) == 0, file.st_mode & S_IFMT == S_IFREG else { return false }
        return UInt32(bitPattern: file.st_dev) == output.pvi.vi_stat.vst_dev
            && file.st_ino == output.pvi.vi_stat.vst_ino
    }

    private func hasIdleListener(_ pid: Int32, port: Int, descriptors: [proc_fdinfo]) -> Bool {
        var foundListener = false
        for descriptor in descriptors where descriptor.proc_fdtype == PROX_FDTYPE_SOCKET {
            var socket = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.stride)
            guard proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, &socket, size) == size else { return false }
            if socket.psi.soi_kind == SOCKINFO_UN,
               Int32(socket.psi.soi_options) & SO_ACCEPTCONN != 0 { return false }
            guard socket.psi.soi_kind == SOCKINFO_TCP else { continue }
            let tcp = socket.psi.soi_proto.pri_tcp
            guard UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport)) == port else { continue }
            guard tcp.tcpsi_state == TSI_S_LISTEN,
                  socket.psi.soi_qlen == 0, socket.psi.soi_incqlen == 0 else { return false }
            foundListener = true
        }
        return foundListener
    }
}
