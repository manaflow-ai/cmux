import Darwin

struct SystemSudoProcessSignaler: SudoProcessSignaling {
    @discardableResult
    func signal(processIdentifier: Int32, signal: Int32) -> Bool {
        guard processIdentifier > 1, processIdentifier != getpid() else { return false }
        return kill(processIdentifier, signal) == 0 || errno == ESRCH
    }

    @discardableResult
    func signal(processGroupIdentifier: Int32, signal: Int32) -> Bool {
        guard processGroupIdentifier > 1, processGroupIdentifier != getpgrp() else { return false }
        return kill(-processGroupIdentifier, signal) == 0 || errno == ESRCH
    }
}
