import Darwin

/// The kernel's identity of one process image: stable for the process's life
/// (`uniqueID`) and changed by every exec (`version`).
///
/// A PID and its start time survive an exec, so they cannot tell whether
/// argv and environment changed; `version` (the kernel's `p_idversion`, the
/// pidversion of an audit token) can. A reused PID gets a new `uniqueID`.
struct CmuxTopProcessExecIdentity: Hashable, Sendable {
    /// `p_uniqueid`: never reused while the machine runs.
    let uniqueID: UInt64
    /// `p_idversion`: a new value on every exec.
    let version: Int32
}

extension CmuxTopProcessExecIdentity {
    /// Reads `pid`'s identity with one `proc_pidinfo` call, or nil when it
    /// cannot be read (exited, another user's, or an older kernel layout).
    ///
    /// `PROC_PIDUNIQIDENTIFIERINFO` (flavor 17) is not in the public SDK; its
    /// 56-byte `proc_uniqidentifierinfo` layout is fixed (`SSHForegroundAuthenticationRetryPolicy`
    /// reads the same fields): uuid[16], uniqueid, puniqueid, idversion.
    static func read(pid: Int) -> CmuxTopProcessExecIdentity? {
        guard pid > 0, pid <= Int(Int32.max) else { return nil }
        let flavor: Int32 = 17
        let size = 56
        var buffer = [UInt8](repeating: 0, count: size)
        let written = buffer.withUnsafeMutableBytes { raw in
            proc_pidinfo(Int32(pid), flavor, 0, raw.baseAddress, Int32(size))
        }
        guard written == Int32(size) else { return nil }
        return buffer.withUnsafeBytes { raw in
            CmuxTopProcessExecIdentity(
                uniqueID: raw.loadUnaligned(fromByteOffset: 16, as: UInt64.self),
                version: raw.loadUnaligned(fromByteOffset: 32, as: Int32.self)
            )
        }
    }
}
