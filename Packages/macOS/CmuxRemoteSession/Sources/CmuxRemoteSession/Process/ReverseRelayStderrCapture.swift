internal import Foundation
internal import CmuxRemoteWorkspace

/// Event-driven stderr tail with bounded startup and drain deadlines.
// SAFETY: synchronous FileHandle and Process callbacks serialize all mutable
// lifecycle state through `lock`; deadline tasks call the same guarded methods.
final class ReverseRelayStderrCapture: @unchecked Sendable {
    // lint:allow lock - callback critical sections only update bounded state.
    private let lock = NSLock()
    private let readHandle: FileHandle
    private let startupMarker: Data?
    private let startupTimeout: TimeInterval?
    private let startupTimeoutHandler: (@Sendable () -> Void)?
    private let startupHandler: (@Sendable () -> Void)?
    private let terminationHandler: @Sendable (String?) -> Void
    private let byteLimit: Int
    private let drainGracePeriod: TimeInterval
    private let clock: any RemoteProxyRetryClock
    private var tail = Data()
    private var startupReported = false
    private var startupExpired = false
    private var sawEOF = false
    private var terminationStatus: Int32?
    private var drainDeadlineScheduled = false
    private var completed = false
    private var startupDeadlineTask: Task<Void, Never>?
    private var drainDeadlineTask: Task<Void, Never>?

    init(
        readHandle: FileHandle,
        byteLimit: Int = 8192,
        drainGracePeriod: TimeInterval,
        startupMarker: String?,
        startupTimeout: TimeInterval?,
        startupTimeoutHandler: (@Sendable () -> Void)?,
        startupHandler: (@Sendable () -> Void)?,
        terminationHandler: @escaping @Sendable (String?) -> Void,
        clock: any RemoteProxyRetryClock
    ) {
        self.readHandle = readHandle
        self.byteLimit = byteLimit
        self.drainGracePeriod = drainGracePeriod
        self.startupMarker = startupMarker?.data(using: .utf8)
        self.startupTimeout = startupTimeout
        self.startupTimeoutHandler = startupTimeoutHandler
        self.startupHandler = startupHandler
        self.terminationHandler = terminationHandler
        self.clock = clock
    }

    func startStartupDeadline() {
        guard let startupTimeout else { return }
        let delayMilliseconds = Int(
            (max(0, startupTimeout) * 1_000).rounded(.up)
        )
        let task = Task { [weak self, clock] in
            guard (try? await clock.sleep(
                forMilliseconds: delayMilliseconds
            )) != nil else {
                return
            }
            self?.startupDeadlineElapsed()
        }
        let retained = lock.withLock {
            guard !startupReported, !startupExpired, !completed else {
                return false
            }
            startupDeadlineTask?.cancel()
            startupDeadlineTask = task
            return true
        }
        if !retained {
            task.cancel()
        }
    }

    func receive(_ data: Data) {
        let result = lock.withLock { () -> (
            completion: (stderr: String, status: Int32)?,
            reportStartup: Bool
        ) in
            if data.isEmpty {
                sawEOF = true
            } else {
                tail.append(data)
                let reportStartup =
                    !completed &&
                    !startupReported &&
                    !startupExpired &&
                    startupMarker.map { tail.range(of: $0) != nil } == true
                if reportStartup {
                    startupReported = true
                }
                if tail.count > byteLimit {
                    tail.removeFirst(tail.count - byteLimit)
                }
                return (takeCompletionIfReady(), reportStartup)
            }
            return (takeCompletionIfReady(), false)
        }
        if result.reportStartup {
            cancelStartupDeadline()
            startupHandler?()
        }
        finish(result.completion)
    }

    func processDidTerminate(status: Int32) {
        let result = lock.withLock { () -> (
            completion: (stderr: String, status: Int32)?,
            scheduleDeadline: Bool
        ) in
            terminationStatus = status
            let completion = takeCompletionIfReady()
            if let completion {
                return (completion, false)
            }
            guard !drainDeadlineScheduled else {
                return (nil, false)
            }
            drainDeadlineScheduled = true
            return (nil, true)
        }
        finish(result.completion)
        if result.scheduleDeadline {
            scheduleDrainDeadline()
        }
    }

    private func scheduleDrainDeadline() {
        let delayMilliseconds = Int(
            (max(0, drainGracePeriod) * 1_000).rounded(.up)
        )
        let task = Task { [weak self, clock] in
            guard (try? await clock.sleep(
                forMilliseconds: delayMilliseconds
            )) != nil else {
                return
            }
            self?.drainDeadlineElapsed()
        }
        let retained = lock.withLock {
            guard !completed else { return false }
            drainDeadlineTask?.cancel()
            drainDeadlineTask = task
            return true
        }
        if !retained {
            task.cancel()
        }
    }

    private func drainDeadlineElapsed() {
        let completion = lock.withLock {
            drainDeadlineTask = nil
            return takeCompletionIfReady(force: true)
        }
        finish(completion)
    }

    private func startupDeadlineElapsed() {
        let shouldTerminate = lock.withLock {
            startupDeadlineTask = nil
            guard !startupReported,
                  !startupExpired,
                  !completed,
                  terminationStatus == nil else {
                return false
            }
            startupExpired = true
            return true
        }
        if shouldTerminate {
            startupTimeoutHandler?()
        }
    }

    private func cancelStartupDeadline() {
        let task = lock.withLock {
            defer { startupDeadlineTask = nil }
            return startupDeadlineTask
        }
        task?.cancel()
    }

    private func takeCompletionIfReady(
        force: Bool = false
    ) -> (stderr: String, status: Int32)? {
        guard !completed,
              (sawEOF || force),
              let terminationStatus else {
            return nil
        }
        completed = true
        return (
            stderr: String(data: tail, encoding: .utf8) ?? "",
            status: terminationStatus
        )
    }

    private func finish(
        _ completion: (stderr: String, status: Int32)?
    ) {
        guard let completion else { return }
        let tasks = lock.withLock {
            let tasks = (startupDeadlineTask, drainDeadlineTask)
            startupDeadlineTask = nil
            drainDeadlineTask = nil
            return tasks
        }
        tasks.0?.cancel()
        tasks.1?.cancel()
        readHandle.readabilityHandler = nil
        try? readHandle.close()
        terminationHandler(
            preferredTerminationDetail(stderr: completion.stderr)
                ?? "status=\(completion.status)"
        )
    }

    private func preferredTerminationDetail(stderr: String) -> String? {
        let lines = stderr
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if let forwardFailure = lines.last(where: {
            $0.localizedCaseInsensitiveContains(
                "remote port forwarding failed for listen"
            )
        }) {
            return forwardFailure
        }
        return RemoteSessionCoordinator.bestErrorLine(stderr: stderr)
    }
}
