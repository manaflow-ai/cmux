import Darwin
import Foundation

/// Terminates a command's process group and optionally reports when every member is gone.
enum CommandProcessTreeTerminator {
    private static let defaultCompletionWaitSeconds: Double = 2
    private static let exitPollInterval = DispatchTimeInterval.milliseconds(10)
    private static let queue = DispatchQueue(label: "com.cmuxterm.CmuxProcess.termination")

    static func terminate(
        _ process: Process,
        processGroupID: pid_t?,
        completionWaitSeconds: Double = defaultCompletionWaitSeconds,
        signalProcessGroup: @escaping @Sendable (pid_t, Int32) -> Void = { processGroupID, signal in
            _ = kill(-processGroupID, signal)
        },
        ownsProcessGroup: @escaping @Sendable (Process, pid_t) -> Bool = { process, processGroupID in
            process.isRunning && getpgid(process.processIdentifier) == processGroupID
        },
        processGroupExists: @escaping @Sendable (pid_t) -> Bool = { processGroupID in
            if kill(-processGroupID, 0) == 0 { return true }
            return errno == EPERM
        },
        completion: (@Sendable (Bool) -> Void)? = nil
    ) {
        if let processGroupID {
            guard ownsProcessGroup(process, processGroupID) else {
                // Lost ownership is safe only when the original numeric group no
                // longer exists. An extant group may have been reused, so never
                // signal it and report cleanup failure instead.
                completion?(!processGroupExists(processGroupID))
                return
            }
            // One immediate signal avoids re-probing a numeric PGID after its original
            // ownership may have disappeared and been reused by an unrelated process.
            signalProcessGroup(processGroupID, SIGKILL)
        } else if process.isRunning {
            let processID = process.processIdentifier
            _ = kill(processID, SIGKILL)
            completion?(false)
            return
        } else {
            completion?(false)
            return
        }

        guard let completion else { return }
        completeWhenProcessTreeIsGone(
            process,
            processGroupID: processGroupID,
            completionWaitSeconds: completionWaitSeconds,
            processGroupExists: processGroupExists,
            completion: completion
        )
    }

    private static func completeWhenProcessTreeIsGone(
        _ process: Process,
        processGroupID: pid_t?,
        completionWaitSeconds: Double,
        processGroupExists: @escaping @Sendable (pid_t) -> Bool,
        completion: @escaping @Sendable (Bool) -> Void
    ) {
        let deadline = DispatchTime.now() + completionWaitSeconds
        let exitTimer = DispatchSource.makeTimerSource(queue: queue)
        exitTimer.schedule(deadline: .now(), repeating: exitPollInterval)
        exitTimer.setEventHandler {
            let isRunning = if let processGroupID {
                processGroupExists(processGroupID)
            } else {
                process.isRunning
            }
            if !isRunning {
                exitTimer.cancel()
                completion(true)
            } else if DispatchTime.now().uptimeNanoseconds >= deadline.uptimeNanoseconds {
                exitTimer.cancel()
                completion(false)
            }
        }
        exitTimer.resume()
    }
}
