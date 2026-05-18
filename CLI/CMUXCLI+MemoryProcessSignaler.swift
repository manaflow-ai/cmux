import Darwin
import Foundation

extension CMUXCLI {
    struct MemoryProcessSignaler {
        let client: SocketClient

        func sendGracefulExit(_ action: MemoryGracefulExitAction, workspaceId: String) throws {
            let params: [String: Any] = [
                "workspace_id": workspaceId,
                "surface_id": action.surfaceId,
                "text": action.text
            ]
            _ = try client.sendV2(method: "surface.send_text", params: params)
        }

        func sendTerminateSignal(pid: Int) -> Bool {
            Darwin.kill(pid_t(pid), SIGTERM) == 0
        }

        func sendKillSignal(pid: Int) -> Bool {
            Darwin.kill(pid_t(pid), SIGKILL) == 0
        }

        func waitForExit(pid: Int, timeout: TimeInterval) -> Bool {
            guard pid > 0 else { return true }
            guard timeout > 0 else { return !isRunning(pid: pid) }
            guard isRunning(pid: pid) else { return true }

            let queue = kqueue()
            guard queue >= 0 else { return !isRunning(pid: pid) }
            defer { Darwin.close(queue) }

            var change = kevent(
                ident: UInt(pid),
                filter: Int16(EVFILT_PROC),
                flags: UInt16(EV_ADD | EV_ENABLE | EV_ONESHOT),
                fflags: UInt32(NOTE_EXIT),
                data: 0,
                udata: nil
            )
            if kevent(queue, &change, 1, nil, 0, nil) == -1 {
                return !isRunning(pid: pid)
            }

            let deadline = Date.now.addingTimeInterval(timeout)
            while true {
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else { return !isRunning(pid: pid) }
                let seconds = floor(remaining)
                var timeoutSpec = timespec(
                    tv_sec: Int(seconds),
                    tv_nsec: Int((remaining - seconds) * 1_000_000_000)
                )
                var event = kevent()
                let result = kevent(queue, nil, 0, &event, 1, &timeoutSpec)
                if result > 0 {
                    return true
                }
                if result == 0 {
                    return !isRunning(pid: pid)
                }
                if errno != EINTR {
                    return !isRunning(pid: pid)
                }
            }
        }

        func isRunning(pid: Int) -> Bool {
            guard pid > 0 else { return false }
            if Darwin.kill(pid_t(pid), 0) == 0 {
                return true
            }
            return errno == EPERM
        }
    }
}
