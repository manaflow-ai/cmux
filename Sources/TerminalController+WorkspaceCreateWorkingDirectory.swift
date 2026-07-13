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
        typealias Probe = @Sendable (_ path: String) async -> Bool
        typealias DeadlineSleep = @Sendable (_ timeout: Duration) async -> Void

        private struct Waiter {
            let path: String
            let continuation: CheckedContinuation<WorkspaceCreateWorkingDirectoryValidation, Never>
            let deadlineTask: Task<Void, Never>
        }

        private let timeout: Duration
        private let maxConcurrentProbes: Int
        private let probe: Probe
        private let sleepUntilDeadline: DeadlineSleep
        private var activePaths: Set<String> = []
        private var queuedPaths: [String] = []
        private var waiterIDsByPath: [String: Set<UUID>] = [:]
        private var waiters: [UUID: Waiter] = [:]
        private var idleWaiters: [CheckedContinuation<Void, Never>] = []

        init(
            timeout: Duration,
            maxConcurrentProbes: Int,
            probe: @escaping Probe,
            sleepUntilDeadline: @escaping DeadlineSleep
        ) {
            precondition(maxConcurrentProbes > 0)
            self.timeout = timeout
            self.maxConcurrentProbes = maxConcurrentProbes
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
            guard !activePaths.isEmpty || !queuedPaths.isEmpty else { return }
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
            if !activePaths.contains(path), !queuedPaths.contains(path) {
                queuedPaths.append(path)
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
                if !activePaths.contains(path) {
                    queuedPaths.removeAll { $0 == path }
                }
            }
            waiter.continuation.resume(returning: result)
        }

        private func startProbesUpToLimit() {
            while activePaths.count < maxConcurrentProbes, !queuedPaths.isEmpty {
                let path = queuedPaths.removeFirst()
                guard waiterIDsByPath[path]?.isEmpty == false else { continue }
                activePaths.insert(path)
                Task { [weak self, probe] in
                    let isDirectory = await probe(path)
                    await self?.completeProbe(path: path, isDirectory: isDirectory)
                }
            }
            resumeIdleWaiters()
        }

        private func completeProbe(path: String, isDirectory: Bool) {
            guard activePaths.remove(path) != nil else { return }
            let waiterIDs = Array(waiterIDsByPath[path] ?? [])
            let result: WorkspaceCreateWorkingDirectoryValidation = isDirectory ? .valid(path) : .invalid
            for waiterID in waiterIDs {
                finishWaiter(waiterID, result: result)
            }
            startProbesUpToLimit()
        }

        private func resumeIdleWaiters() {
            guard activePaths.isEmpty, queuedPaths.isEmpty else { return }
            let continuations = idleWaiters
            idleWaiters = []
            for continuation in continuations { continuation.resume() }
        }
    }

    nonisolated static let v2MobileWorkingDirectoryValidationService =
        WorkspaceCreateWorkingDirectoryValidationService(
            timeout: .seconds(3),
            maxConcurrentProbes: 2,
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
