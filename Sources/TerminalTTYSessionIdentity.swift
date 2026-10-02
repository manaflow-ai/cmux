import CmuxFoundation
import Darwin
import Foundation

/// Identifies the process generation that owns one terminal session.
///
/// A PTY name can be reused after its session exits. Pairing the session-leader
/// PID with its process start time distinguishes the new terminal generation
/// from a stale report that happened to use the same device name.
struct TerminalTTYSessionIdentity: Equatable, Sendable {
    let processIdentity: AgentPIDProcessIdentity

    init(processIdentity: AgentPIDProcessIdentity) {
        self.processIdentity = processIdentity
    }

    init?(ttyName: String) {
        let trimmedName = ttyName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, trimmedName != "not a tty" else { return nil }
        let deviceName = trimmedName.split(separator: "/").last.map(String.init) ?? trimmedName
        // Do not open the reported PTY here. On macOS, a blocked opener can
        // hold the device lock before PTY carrier handling sees O_NONBLOCK.
        // This initializer is called from main-actor notification and port
        // registration paths, so an open can freeze the entire app.
        guard let sessionLeaderPID = Self.sessionLeaderPID(forDeviceNamed: deviceName) else {
            return nil
        }
        guard let processIdentity = AgentPIDProcessIdentity(pid: sessionLeaderPID) else { return nil }
        self.processIdentity = processIdentity
    }

    /// Finds the unique session leader for a controlling tty without opening
    /// the tty device. `KERN_PROC_TTY` reads the kernel process table by the
    /// device id and avoids the uninterruptible `open(2)` path entirely.
    static func sessionLeaderPID(forDeviceNamed deviceName: String) -> pid_t? {
        var metadata = stat()
        guard Darwin.stat("/dev/\(deviceName)", &metadata) == 0 else { return nil }

        var mib: [Int32] = [
            CTL_KERN,
            KERN_PROC,
            KERN_PROC_TTY,
            Int32(truncatingIfNeeded: metadata.st_rdev)
        ]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0,
              size > 0 else {
            return nil
        }

        let stride = MemoryLayout<kinfo_proc>.stride
        guard stride > 0 else { return nil }
        var processes = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 1)
        size = processes.count * stride
        guard sysctl(&mib, UInt32(mib.count), &processes, &size, nil, 0) == 0 else {
            return nil
        }

        let leaders = processes.prefix(size / stride).filter {
            ($0.kp_eproc.e_flag & EPROC_SLEADER) != 0 && $0.kp_proc.p_pid > 1
        }
        guard leaders.count == 1 else { return nil }
        return leaders[0].kp_proc.p_pid
    }
}
