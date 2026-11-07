import CmuxFoundation
import Darwin
import Foundation

/// A process generation and its controlling terminal, read only on the socket worker.
struct SurfaceIconProcessEvidence: Sendable, Equatable {
    let identity: AgentPIDProcessIdentity
    let processGroup: Int32
    let terminalDevice: UInt32
    let startDescription: String

    init?(pid: Int) {
        guard let pid = pid_t(exactly: pid), pid > 1,
              let identity = AgentPIDProcessIdentity(pid: pid) else { return nil }
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.stride
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size)) == size,
              info.pbi_uid == getuid(), info.e_tdev != UInt32.max else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        self.identity = identity
        processGroup = Int32(bitPattern: info.pbi_pgid)
        terminalDevice = info.e_tdev
        startDescription = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(identity.startSeconds)))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
