import Foundation

extension TerminalController {
    /// Coalesces bounded working-directory probes and quarantines wedged work.
    actor WorkspaceCreateWorkingDirectoryValidationService {
        enum ProbeLane: Equatable, Sendable {
            case local
            case external
        }

        typealias Probe = @Sendable (_ path: String) async -> Bool
        typealias LaneClassifier = @Sendable (_ path: String) -> ProbeLane
        typealias DeadlineSleep = @Sendable (_ timeout: Duration) async -> Void

        private struct QueuedProbe {
            let path: String
            let lane: ProbeLane
        }

        private struct Waiter {
            let path: String
            let continuation: CheckedContinuation<WorkspaceCreateWorkingDirectoryValidation, Never>
            let deadlineTask: Task<Void, Never>
        }

        private let timeout: Duration
        private let localCapacity: Int
        private let externalCapacity: Int
        private let laneClassifier: LaneClassifier
        private let probe: Probe
        private let sleepUntilDeadline: DeadlineSleep
        private var activeLanesByPath: [String: ProbeLane] = [:]
        private var queuedProbes: [QueuedProbe] = []
        private var waiterIDsByPath: [String: Set<UUID>] = [:]
        private var waiters: [UUID: Waiter] = [:]

        init(
            timeout: Duration,
            localCapacity: Int,
            externalCapacity: Int,
            laneClassifier: @escaping LaneClassifier,
            probe: @escaping Probe,
            sleepUntilDeadline: @escaping DeadlineSleep
        ) {
            precondition(localCapacity > 0 && externalCapacity > 0)
            self.timeout = timeout
            self.localCapacity = localCapacity
            self.externalCapacity = externalCapacity
            self.laneClassifier = laneClassifier
            self.probe = probe
            self.sleepUntilDeadline = sleepUntilDeadline
        }

        func validate(
            rawValue: String?,
            isProvided: Bool
        ) async -> WorkspaceCreateWorkingDirectoryValidation {
            guard isProvided else { return .notProvided }
            guard let path = TerminalController.v2ExpandedWorkingDirectory(rawValue),
                  (path as NSString).isAbsolutePath else {
                return .invalid
            }
            guard !Task.isCancelled else { return .cancelled }
            let waiterID = UUID()
            return await withTaskCancellationHandler {
                guard !Task.isCancelled else { return .cancelled }
                return await withCheckedContinuation { continuation in
                    register(waiterID: waiterID, path: path, continuation: continuation)
                }
            } onCancel: {
                Task { await self.cancelWaiter(waiterID) }
            }
        }

        private func register(
            waiterID: UUID,
            path: String,
            continuation: CheckedContinuation<WorkspaceCreateWorkingDirectoryValidation, Never>
        ) {
            let deadlineTask = Task { [weak self, sleepUntilDeadline, timeout] in
                await sleepUntilDeadline(timeout)
                guard !Task.isCancelled else { return }
                await self?.timeoutWaiter(waiterID)
            }
            waiters[waiterID] = Waiter(
                path: path,
                continuation: continuation,
                deadlineTask: deadlineTask
            )
            waiterIDsByPath[path, default: []].insert(waiterID)
            if activeLanesByPath[path] == nil, !queuedProbes.contains(where: { $0.path == path }) {
                queuedProbes.append(QueuedProbe(path: path, lane: laneClassifier(path)))
            }
            startProbesUpToLimit()
        }

        private func cancelWaiter(_ waiterID: UUID) {
            guard waiters[waiterID] != nil else { return }
            finishWaiter(waiterID, result: .cancelled)
        }

        private func timeoutWaiter(_ waiterID: UUID) {
            finishWaiter(waiterID, result: .timedOut)
        }

        private func finishWaiter(
            _ waiterID: UUID,
            result: WorkspaceCreateWorkingDirectoryValidation
        ) {
            guard let waiter = waiters.removeValue(forKey: waiterID) else { return }
            let path = waiter.path
            waiter.deadlineTask.cancel()
            waiterIDsByPath[path]?.remove(waiterID)
            if waiterIDsByPath[path]?.isEmpty == true {
                waiterIDsByPath.removeValue(forKey: path)
                if activeLanesByPath[path] == nil {
                    queuedProbes.removeAll { $0.path == path }
                }
            }
            waiter.continuation.resume(returning: result)
        }

        private func startProbesUpToLimit() {
            while let index = queuedProbes.firstIndex(where: { hasCapacity(for: $0.lane) }) {
                let queued = queuedProbes.remove(at: index)
                let path = queued.path
                guard waiterIDsByPath[path]?.isEmpty == false else { continue }
                activeLanesByPath[path] = queued.lane
                Task { [weak self, probe] in
                    let isDirectory = await probe(path)
                    await self?.completeProbe(path: path, isDirectory: isDirectory)
                }
            }
        }

        private func completeProbe(path: String, isDirectory: Bool) {
            guard activeLanesByPath.removeValue(forKey: path) != nil else { return }
            let waiterIDs = Array(waiterIDsByPath[path] ?? [])
            let result: WorkspaceCreateWorkingDirectoryValidation = isDirectory ? .valid(path) : .invalid
            for waiterID in waiterIDs {
                finishWaiter(waiterID, result: result)
            }
            startProbesUpToLimit()
        }

        private func hasCapacity(for lane: ProbeLane) -> Bool {
            let activeCount = activeLanesByPath.values.reduce(into: 0) { count, activeLane in
                if activeLane == lane { count += 1 }
            }
            switch lane {
            case .local:
                return activeCount < localCapacity
            case .external:
                return activeCount < externalCapacity
            }
        }
    }
}
