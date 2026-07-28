import Foundation

extension TerminalController {
    /// Coalesces bounded working-directory probes and quarantines wedged work.
    actor WorkspaceCreateWorkingDirectoryValidationService {
        enum ProbeLane: Equatable, Sendable {
            case local
            case external
        }

        typealias Probe = @Sendable (_ path: String, _ lane: ProbeLane) async -> Bool
        typealias BlockingCanonicalProbe = @Sendable (
            _ path: String,
            _ lane: ProbeLane,
            _ probeVariant: String?
        ) -> WorkspaceCreateWorkingDirectoryCanonicalProbeResult
        typealias LaneClassifier = @Sendable (_ path: String) async -> ProbeLane
        typealias PathResolver = @Sendable (_ rawValue: String) -> String?
        typealias DeadlineSleep = @Sendable (_ timeout: Duration) async -> Void

        private struct QueuedProbe {
            let key: WorkspaceCreateWorkingDirectoryProbeKey
            let path: String
            let lane: ProbeLane
        }

        private struct QueuedClassification {
            let key: WorkspaceCreateWorkingDirectoryProbeKey
            let path: String
        }

        private struct Waiter {
            let key: WorkspaceCreateWorkingDirectoryProbeKey
            let continuation: CheckedContinuation<WorkspaceCreateWorkingDirectoryValidation, Never>
            let deadlineTask: Task<Void, Never>
        }

        private let timeout: Duration
        private let localCapacity: Int
        private let externalCapacity: Int
        private let classificationCapacity: Int
        private let maximumPendingWaiters: Int
        private let maximumPathUTF8Bytes: Int
        private let pathResolver: PathResolver
        private let laneClassifier: LaneClassifier
        private let canonicalProbe: @Sendable (
            _ path: String,
            _ lane: ProbeLane,
            _ probeVariant: String?
        ) async -> WorkspaceCreateWorkingDirectoryCanonicalProbeResult
        private let sleepUntilDeadline: DeadlineSleep
        private var activeLanesByPath: [WorkspaceCreateWorkingDirectoryProbeKey: ProbeLane] = [:]
        private var queuedProbes: [QueuedProbe] = []
        private var classifyingPathIDs: Set<WorkspaceCreateWorkingDirectoryProbeKey> = []
        private var queuedClassifications: [QueuedClassification] = []
        private var waiterIDsByPath: [WorkspaceCreateWorkingDirectoryProbeKey: Set<UUID>] = [:]
        private var waiters: [UUID: Waiter] = [:]

        init(
            timeout: Duration,
            localCapacity: Int,
            externalCapacity: Int,
            classificationCapacity: Int = 3,
            maximumPendingWaiters: Int,
            maximumPathUTF8Bytes: Int = 4_096,
            pathResolver: @escaping PathResolver = {
                guard let path = TerminalController.v2ExpandedWorkingDirectory($0),
                      (path as NSString).isAbsolutePath,
                      !TerminalController.v2WorkingDirectoryContainsDotComponent(path) else {
                    return nil
                }
                return path
            },
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
            self.pathResolver = pathResolver
            self.laneClassifier = laneClassifier
            canonicalProbe = { path, lane, _ in
                await probe(path, lane) ? .valid(path) : .invalid
            }
            self.sleepUntilDeadline = sleepUntilDeadline
        }

        /// Creates a bounded service for blocking probes that return a
        /// kernel-canonical path. The synchronous probe always runs in a
        /// detached utility worker, while this actor retains its capacity lane
        /// until that worker exits, including after caller timeout.
        init(
            timeout: Duration,
            localCapacity: Int,
            externalCapacity: Int,
            classificationCapacity: Int = 3,
            maximumPendingWaiters: Int,
            maximumPathUTF8Bytes: Int = 4_096,
            pathResolver: @escaping PathResolver,
            laneClassifier: @escaping LaneClassifier,
            blockingCanonicalProbe: @escaping BlockingCanonicalProbe,
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
            self.pathResolver = pathResolver
            self.laneClassifier = laneClassifier
            canonicalProbe = { path, lane, probeVariant in
                await Task.detached(priority: .utility) {
                    blockingCanonicalProbe(path, lane, probeVariant)
                }.value
            }
            self.sleepUntilDeadline = sleepUntilDeadline
        }

        func validate(
            rawValue: String?,
            isProvided: Bool,
            timeoutOverride: Duration? = nil,
            probeVariant: String? = nil
        ) async -> WorkspaceCreateWorkingDirectoryValidation {
            guard isProvided else { return .notProvided }
            guard let rawValue, rawValue.utf8.count <= maximumPathUTF8Bytes else {
                return .invalid
            }
            guard let path = pathResolver(rawValue),
                  path.utf8.count <= maximumPathUTF8Bytes else {
                return .invalid
            }
            guard !Task.isCancelled else { return .cancelled }
            let waiterID = UUID()
            return await withTaskCancellationHandler {
                guard !Task.isCancelled else { return .cancelled }
                return await withCheckedContinuation { continuation in
                    register(
                        waiterID: waiterID,
                        path: path,
                        probeVariant: probeVariant,
                        timeout: timeoutOverride ?? timeout,
                        continuation: continuation
                    )
                }
            } onCancel: {
                Task { await self.cancelWaiter(waiterID) }
            }
        }

        private func register(
            waiterID: UUID,
            path: String,
            probeVariant: String?,
            timeout: Duration,
            continuation: CheckedContinuation<WorkspaceCreateWorkingDirectoryValidation, Never>
        ) {
            guard waiters.count < maximumPendingWaiters else {
                continuation.resume(returning: .busy)
                return
            }
            let deadlineTask = Task { [weak self, sleepUntilDeadline] in
                await sleepUntilDeadline(timeout)
                guard !Task.isCancelled else { return }
                await self?.timeoutWaiter(waiterID)
            }
            let key = WorkspaceCreateWorkingDirectoryProbeKey(
                pathID: Data(path.utf8),
                probeVariant: probeVariant
            )
            waiters[waiterID] = Waiter(
                key: key,
                continuation: continuation,
                deadlineTask: deadlineTask
            )
            waiterIDsByPath[key, default: []].insert(waiterID)
            if activeLanesByPath[key] == nil,
               !classifyingPathIDs.contains(key),
               !queuedClassifications.contains(where: { $0.key == key }),
               !queuedProbes.contains(where: { $0.key == key }) {
                queuedClassifications.append(QueuedClassification(key: key, path: path))
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
            let key = waiter.key
            waiter.deadlineTask.cancel()
            waiterIDsByPath[key]?.remove(waiterID)
            if waiterIDsByPath[key]?.isEmpty == true {
                waiterIDsByPath.removeValue(forKey: key)
                if activeLanesByPath[key] == nil {
                    queuedClassifications.removeAll { $0.key == key }
                    queuedProbes.removeAll { $0.key == key }
                }
            }
            waiter.continuation.resume(returning: result)
        }

        private func startClassificationsUpToLimit() {
            while classifyingPathIDs.count < classificationCapacity,
                  !queuedClassifications.isEmpty {
                let queued = queuedClassifications.removeFirst()
                guard waiterIDsByPath[queued.key]?.isEmpty == false else { continue }
                classifyingPathIDs.insert(queued.key)
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
            guard classifyingPathIDs.remove(classification.key) != nil else { return }
            if waiterIDsByPath[classification.key]?.isEmpty == false {
                queuedProbes.append(QueuedProbe(
                    key: classification.key,
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
                let key = queued.key
                let path = queued.path
                guard waiterIDsByPath[key]?.isEmpty == false else { continue }
                activeLanesByPath[key] = queued.lane
                Task { [weak self, canonicalProbe, lane = queued.lane] in
                    let probeResult = await canonicalProbe(
                        path,
                        lane,
                        key.probeVariant
                    )
                    await self?.completeProbe(
                        key: key,
                        probeResult: probeResult
                    )
                }
            }
        }

        private func completeProbe(
            key: WorkspaceCreateWorkingDirectoryProbeKey,
            probeResult: WorkspaceCreateWorkingDirectoryCanonicalProbeResult
        ) {
            guard activeLanesByPath.removeValue(forKey: key) != nil else { return }
            let waiterIDs = Array(waiterIDsByPath[key] ?? [])
            let result: WorkspaceCreateWorkingDirectoryValidation
            switch probeResult {
            case .valid(let canonicalPath):
                result = .valid(canonicalPath)
            case .invalid:
                result = .invalid
            case .wrongFileType:
                result = .wrongFileType
            }
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
