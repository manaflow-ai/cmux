import Darwin
import Foundation

extension TerminalController {
    enum WorkspaceCreateWorkingDirectoryValidation: Equatable, Sendable {
        case notProvided
        case valid(String)
        case invalid
        case timedOut
        case cancelled
    }

    typealias WorkspaceCreateWorkingDirectoryValidator = @Sendable (
        _ rawValue: String?,
        _ isProvided: Bool
    ) async -> WorkspaceCreateWorkingDirectoryValidation

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
        private var idleWaiters: [CheckedContinuation<Void, Never>] = []

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

        func waiterCountForTesting() -> Int {
            waiters.count
        }

        func waitUntilIdleForTesting() async {
            guard !activeLanesByPath.isEmpty || !queuedProbes.isEmpty else { return }
            await withCheckedContinuation { idleWaiters.append($0) }
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
            resumeIdleWaiters()
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

        private func resumeIdleWaiters() {
            guard activeLanesByPath.isEmpty, queuedProbes.isEmpty else { return }
            let continuations = idleWaiters
            idleWaiters = []
            for continuation in continuations { continuation.resume() }
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

    nonisolated static let v2MobileWorkingDirectoryValidationService =
        WorkspaceCreateWorkingDirectoryValidationService(
            timeout: .seconds(3),
            localCapacity: 1,
            externalCapacity: 2,
            laneClassifier: v2WorkingDirectoryProbeLane,
            probe: { path in
                await Task.detached(priority: .utility) {
                    var isDirectory: ObjCBool = false
                    return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                        && isDirectory.boolValue
                }.value
            },
            sleepUntilDeadline: { timeout in
                try? await ContinuousClock().sleep(for: timeout)
            }
        )

    nonisolated static func v2WorkingDirectoryProbeLane(
        _ path: String
    ) -> WorkspaceCreateWorkingDirectoryValidationService.ProbeLane {
        var mounts: UnsafeMutablePointer<statfs>?
        let mountCount = getmntinfo(&mounts, MNT_NOWAIT)
        guard mountCount > 0, let mounts else { return .external }
        let normalizedPath = (path as NSString).standardizingPath
        var longestMatchLength = -1
        var longestMatchIsLocal = false
        for index in 0..<Int(mountCount) {
            let fileSystem = mounts[index]
            let mountPath = withUnsafePointer(to: fileSystem.f_mntonname) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: 1) {
                    String(cString: $0)
                }
            }
            let matches = normalizedPath == mountPath
                || normalizedPath.hasPrefix(mountPath == "/" ? "/" : "\(mountPath)/")
            guard matches, mountPath.count > longestMatchLength else { continue }
            longestMatchLength = mountPath.count
            longestMatchIsLocal = (fileSystem.f_flags & UInt32(MNT_LOCAL)) != 0
        }
        return longestMatchIsLocal ? .local : .external
    }

    nonisolated static var v2InvalidWorkingDirectoryResult: V2CallResult {
        .err(
            code: "invalid_params",
            message: "working_directory must be an absolute existing directory",
            data: ["field": "working_directory"]
        )
    }

    nonisolated static func v2ValidateMobileWorkingDirectory(
        rawValue: String?,
        isProvided: Bool
    ) async -> WorkspaceCreateWorkingDirectoryValidation {
        guard !Task.isCancelled else { return .cancelled }
        let validation = await v2MobileWorkingDirectoryValidationService.validate(
            rawValue: rawValue,
            isProvided: isProvided
        )
        guard !Task.isCancelled else { return .cancelled }
        return validation
    }
}
