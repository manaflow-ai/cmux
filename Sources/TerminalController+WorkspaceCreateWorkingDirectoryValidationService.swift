import Foundation

extension TerminalController {
    /// Coalesces bounded working-directory probes and quarantines wedged work.
    actor WorkspaceCreateWorkingDirectoryValidationService {
        enum ProbeLane: Equatable, Sendable {
            case local
            case external
        }

        typealias Probe = @Sendable (_ path: String, _ lane: ProbeLane) async -> Bool
        typealias LaneClassifier = @Sendable (_ path: String) async -> ProbeLane
        typealias DeadlineSleep = @Sendable (_ timeout: Duration) async -> Void

        private struct QueuedProbe {
            let pathID: Data
            let path: String
            let lane: ProbeLane
        }

        private struct QueuedClassification {
            let pathID: Data
            let path: String
        }

        private struct Waiter {
            let pathID: Data
            let continuation: CheckedContinuation<WorkspaceCreateWorkingDirectoryValidation, Never>
            let deadlineTask: Task<Void, Never>
        }

        private let timeout: Duration
        private let localCapacity: Int
        private let externalCapacity: Int
        private let classificationCapacity: Int
        private let maximumPendingWaiters: Int
        private let maximumPathUTF8Bytes: Int
        private let laneClassifier: LaneClassifier
        private let probe: Probe
        private let sleepUntilDeadline: DeadlineSleep
        private var activeLanesByPath: [Data: ProbeLane] = [:]
        private var queuedProbes: [QueuedProbe] = []
        private var classifyingPathIDs: Set<Data> = []
        private var queuedClassifications: [QueuedClassification] = []
        private var waiterIDsByPath: [Data: Set<UUID>] = [:]
        private var waiters: [UUID: Waiter] = [:]

        init(
            timeout: Duration,
            localCapacity: Int,
            externalCapacity: Int,
            classificationCapacity: Int = 3,
            maximumPendingWaiters: Int,
            maximumPathUTF8Bytes: Int = 4_096,
            laneClassifier: @escaping LaneClassifier,
            probe: @escaping Probe,
            sleepUntilDeadline: @escaping DeadlineSleep
        ) {
            precondition(
                localCapacity > 0 && externalCapacity > 0 && classificationCapacity > 0
                    && maximumPendingWaiters > 0 && maximumPathUTF8Bytes > 0
            )
            self.timeout = timeout
            self.localCapacity = localCapacity
            self.externalCapacity = externalCapacity
            self.classificationCapacity = classificationCapacity
            self.maximumPendingWaiters = maximumPendingWaiters
            self.maximumPathUTF8Bytes = maximumPathUTF8Bytes
            self.laneClassifier = laneClassifier
            self.probe = probe
            self.sleepUntilDeadline = sleepUntilDeadline
        }

        func validate(
            rawValue: String?,
            isProvided: Bool
        ) async -> WorkspaceCreateWorkingDirectoryValidation {
            guard isProvided else { return .notProvided }
            guard let rawValue, rawValue.utf8.count <= maximumPathUTF8Bytes else {
                return .invalid
            }
            guard let path = TerminalController.v2ExpandedWorkingDirectory(rawValue),
                  path.utf8.count <= maximumPathUTF8Bytes,
                  (path as NSString).isAbsolutePath,
                  !TerminalController.v2WorkingDirectoryContainsDotComponent(path) else {
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
            guard waiters.count < maximumPendingWaiters else {
                continuation.resume(returning: .busy)
                return
            }
            let deadlineTask = Task { [weak self, sleepUntilDeadline, timeout] in
                await sleepUntilDeadline(timeout)
                guard !Task.isCancelled else { return }
                await self?.timeoutWaiter(waiterID)
            }
            let pathID = Data(path.utf8)
            waiters[waiterID] = Waiter(
                pathID: pathID,
                continuation: continuation,
                deadlineTask: deadlineTask
            )
            waiterIDsByPath[pathID, default: []].insert(waiterID)
            if activeLanesByPath[pathID] == nil,
               !classifyingPathIDs.contains(pathID),
               !queuedClassifications.contains(where: { $0.pathID == pathID }),
               !queuedProbes.contains(where: { $0.pathID == pathID }) {
                queuedClassifications.append(QueuedClassification(pathID: pathID, path: path))
            }
            startClassificationsUpToLimit()
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
            let pathID = waiter.pathID
            waiter.deadlineTask.cancel()
            waiterIDsByPath[pathID]?.remove(waiterID)
            if waiterIDsByPath[pathID]?.isEmpty == true {
                waiterIDsByPath.removeValue(forKey: pathID)
                if activeLanesByPath[pathID] == nil {
                    queuedClassifications.removeAll { $0.pathID == pathID }
                    queuedProbes.removeAll { $0.pathID == pathID }
                }
            }
            waiter.continuation.resume(returning: result)
        }

        private func startClassificationsUpToLimit() {
            while classifyingPathIDs.count < classificationCapacity,
                  !queuedClassifications.isEmpty {
                let queued = queuedClassifications.removeFirst()
                guard waiterIDsByPath[queued.pathID]?.isEmpty == false else { continue }
                classifyingPathIDs.insert(queued.pathID)
                Task.detached(priority: .utility) { [weak self, laneClassifier] in
                    let lane = await laneClassifier(queued.path)
                    await self?.completeClassification(queued, lane: lane)
                }
            }
        }

        private func completeClassification(
            _ classification: QueuedClassification,
            lane: ProbeLane
        ) {
            guard classifyingPathIDs.remove(classification.pathID) != nil else { return }
            if waiterIDsByPath[classification.pathID]?.isEmpty == false {
                queuedProbes.append(QueuedProbe(
                    pathID: classification.pathID,
                    path: classification.path,
                    lane: lane
                ))
            }
            startClassificationsUpToLimit()
            startProbesUpToLimit()
        }

        private func startProbesUpToLimit() {
            while let index = queuedProbes.firstIndex(where: { hasCapacity(for: $0.lane) }) {
                let queued = queuedProbes.remove(at: index)
                let pathID = queued.pathID
                let path = queued.path
                guard waiterIDsByPath[pathID]?.isEmpty == false else { continue }
                activeLanesByPath[pathID] = queued.lane
                Task { [weak self, probe, lane = queued.lane] in
                    let isDirectory = await probe(path, lane)
                    await self?.completeProbe(
                        pathID: pathID,
                        path: path,
                        isDirectory: isDirectory
                    )
                }
            }
        }

        private func completeProbe(pathID: Data, path: String, isDirectory: Bool) {
            guard activeLanesByPath.removeValue(forKey: pathID) != nil else { return }
            let waiterIDs = Array(waiterIDsByPath[pathID] ?? [])
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
