import Darwin
import Foundation

extension VSCodeServeWebController {
    func restartAfterOwnedProcessExit(
        vscodeApplicationURL: URL,
        completion: @escaping (URL?) -> Void
    ) {
        let (restartGeneration, processes, cancelledCompletions): (UInt64, [Process], [(URL?) -> Void]) = queue.sync(execute: {
            self.lifecycleGeneration &+= 1
            let restartGeneration = self.lifecycleGeneration
            self.isLaunching = true
            self.activeLaunchGeneration = restartGeneration
            var processes: [Process] = []
            if let process = self.serveWebProcess {
                processes.append(process)
            }
            if let process = self.launchingProcess,
               !processes.contains(where: { $0 === process }) {
                processes.append(process)
            }
            self.serveWebProcess = nil
            self.launchingProcess = nil
            self.serveWebURL = nil
            let cancelledCompletions = self.pendingCompletions.map(\.completion)
            self.pendingCompletions.removeAll()
            self.pendingCompletions.append((generation: restartGeneration, completion: completion))
            return (restartGeneration, processes, cancelledCompletions)
        })

        if !cancelledCompletions.isEmpty {
            Self.completeOnMain(cancelledCompletions, with: nil)
        }

        terminateProcessesBeforeRestart(processes) { [weak self] didTerminate in
            guard let self else { return }
            guard didTerminate else {
                self.completeServeWebLaunch(nil, expectedGeneration: restartGeneration)
                return
            }

            self.launchQueue.async {
                let shouldLaunch = self.queue.sync(execute: {
                    self.lifecycleGeneration == restartGeneration
                        && self.activeLaunchGeneration == restartGeneration
                })
                guard shouldLaunch else { return }
                self.launchServeWebProcess(
                    vscodeApplicationURL: vscodeApplicationURL,
                    expectedGeneration: restartGeneration
                )
            }
        }
    }

    private func terminateProcessesBeforeRestart(
        _ processes: [Process],
        completion: @escaping (Bool) -> Void
    ) {
        let runningProcesses = processes.filter(\.isRunning)
        guard !runningProcesses.isEmpty else {
            completion(true)
            return
        }

        queue.async {
            var remainingProcessIDs = Set(runningProcesses.map { ObjectIdentifier($0) })
            var terminationTimer: DispatchSourceTimer?
            var killTimer: DispatchSourceTimer?
            var didComplete = false

            func complete(_ didTerminate: Bool) {
                guard !didComplete else { return }
                didComplete = true
                terminationTimer?.cancel()
                killTimer?.cancel()
                terminationTimer = nil
                killTimer = nil
                completion(didTerminate)
            }

            func markTerminated(_ process: Process) {
                remainingProcessIDs.remove(ObjectIdentifier(process))
                if remainingProcessIDs.isEmpty {
                    complete(true)
                }
            }

            for process in runningProcesses {
                let previousTerminationHandler = process.terminationHandler
                process.terminationHandler = { [weak self] terminatedProcess in
                    previousTerminationHandler?(terminatedProcess)
                    self?.queue.async {
                        markTerminated(terminatedProcess)
                    }
                }
            }

            for process in runningProcesses {
                if process.isRunning {
                    process.terminate()
                } else {
                    markTerminated(process)
                }
            }

            guard !remainingProcessIDs.isEmpty else { return }

            // Restart must be ordered after process exit so our stable-port retry
            // does not fall back to port 0 while the old server is still exiting.
            terminationTimer = DispatchSource.makeTimerSource(queue: self.queue)
            terminationTimer?.schedule(deadline: .now() + Self.serveWebTerminationTimeoutSeconds)
            terminationTimer?.setEventHandler {
                for process in runningProcesses
                where remainingProcessIDs.contains(ObjectIdentifier(process)) && process.isRunning {
                    _ = Darwin.kill(process.processIdentifier, SIGKILL)
                }

                killTimer = DispatchSource.makeTimerSource(queue: self.queue)
                killTimer?.schedule(deadline: .now() + Self.serveWebKillTimeoutSeconds)
                killTimer?.setEventHandler {
                    for process in runningProcesses
                    where remainingProcessIDs.contains(ObjectIdentifier(process)) && !process.isRunning {
                        markTerminated(process)
                    }
                    if !remainingProcessIDs.isEmpty {
                        complete(false)
                    }
                }
                killTimer?.resume()
            }
            terminationTimer?.resume()
        }
    }
}
