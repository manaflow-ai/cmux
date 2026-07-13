import Darwin
import Foundation

/// Terminates a command's process group and optionally reports when every member is gone.
enum CommandProcessTreeTerminator {
    private static let sigkillGraceSeconds: Double = 0.2
    private static let exitPollInterval = DispatchTimeInterval.milliseconds(10)
    private static let queue = DispatchQueue(label: "com.cmuxterm.CmuxProcess.termination")

    static func terminate(
        _ process: Process,
        processGroupID: pid_t?,
        completion: (@Sendable () -> Void)? = nil
    ) {
        let terminationGroupID: pid_t? = if let processGroupID {
            processGroupID
        } else if !process.isRunning,
                  process.processIdentifier > 1,
                  process.processIdentifier != getpgrp() {
            process.processIdentifier
        } else {
            nil
        }

        if let terminationGroupID {
            _ = kill(-terminationGroupID, SIGTERM)
        } else if process.isRunning {
            process.terminate()
        } else {
            completion?()
            return
        }

        let escalationTimer = DispatchSource.makeTimerSource(queue: queue)
        escalationTimer.schedule(deadline: .now() + sigkillGraceSeconds)
        escalationTimer.setEventHandler {
            if let terminationGroupID {
                if processGroupExists(terminationGroupID) {
                    _ = kill(-terminationGroupID, SIGKILL)
                }
            } else if process.isRunning {
                _ = kill(process.processIdentifier, SIGKILL)
            }
            escalationTimer.cancel()

            if let completion {
                completeWhenProcessTreeIsGone(
                    process,
                    processGroupID: terminationGroupID,
                    completion: completion
                )
            }
        }
        escalationTimer.resume()
    }

    private static func completeWhenProcessTreeIsGone(
        _ process: Process,
        processGroupID: pid_t?,
        completion: @escaping @Sendable () -> Void
    ) {
        let exitTimer = DispatchSource.makeTimerSource(queue: queue)
        exitTimer.schedule(deadline: .now(), repeating: exitPollInterval)
        exitTimer.setEventHandler {
            let isRunning = if let processGroupID {
                processGroupExists(processGroupID)
            } else {
                process.isRunning
            }
            guard !isRunning else { return }
            exitTimer.cancel()
            completion()
        }
        exitTimer.resume()
    }

    private static func processGroupExists(_ processGroupID: pid_t) -> Bool {
        if kill(-processGroupID, 0) == 0 { return true }
        return errno == EPERM
    }
}
