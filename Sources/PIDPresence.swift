import Darwin

/// Best-effort operating-system evidence that a process ID still exists.
enum PIDPresence: Equatable, Sendable {
    case present
    case absent
    case unknown

    static func current(pid: pid_t) -> Self {
        guard pid > 0 else { return .absent }
        errno = 0
        guard kill(pid, 0) != 0 else { return .present }
        switch errno {
        case EPERM:
            return .present
        case ESRCH:
            return .absent
        default:
            return .unknown
        }
    }
}
