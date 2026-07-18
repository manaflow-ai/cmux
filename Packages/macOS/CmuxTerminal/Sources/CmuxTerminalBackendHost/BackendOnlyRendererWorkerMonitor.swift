internal import CmuxTerminalBackend
internal import Darwin
internal import Dispatch
internal import Foundation

struct BackendOnlyRendererWorkerIdentity: Hashable, Sendable {
    let daemonInstanceID: UUID
    let rendererEpoch: UInt64
    let processID: pid_t
    let effectiveUserID: UInt32
    let processInstanceToken: BackendRendererProcessInstanceToken
}

final class BackendOnlyRendererWorkerExitFence: @unchecked Sendable {
    private let lock = NSLock()
    private var exited = false

    var hasExited: Bool {
        lock.lock()
        defer { lock.unlock() }
        return exited
    }

    func finish() {
        lock.lock()
        exited = true
        lock.unlock()
    }
}

enum BackendOnlyRendererWorkerWatchResult: Sendable {
    case watching(BackendOnlyRendererWorkerExitFence)
    case alreadyExited
    case unverifiable
}

/// Arms NOTE_EXIT before validating the exact public-kernel start tuple.
///
/// The daemon separately validates the same tuple during activation. Together
/// those checks close PID-reuse and exit-between-check-and-activation races.
final class BackendOnlyRendererWorkerMonitor: @unchecked Sendable {
    private struct Registration {
        let source: any DispatchSourceProcess
        let fence: BackendOnlyRendererWorkerExitFence
        let onExit: @Sendable (BackendOnlyRendererWorkerIdentity) -> Void
    }

    private enum ProcessLookup {
        case exact(BackendRendererProcessInstanceToken)
        case missing
        case unverifiable
    }

    private let lock = NSLock()
    private let queue = DispatchQueue(
        label: "com.cmux.backend-only.renderer-worker-exit",
        qos: .userInitiated
    )
    private var registrations: [BackendOnlyRendererWorkerIdentity: Registration] = [:]

    func watch(
        _ identity: BackendOnlyRendererWorkerIdentity,
        onExit: @escaping @Sendable (BackendOnlyRendererWorkerIdentity) -> Void
    ) -> BackendOnlyRendererWorkerWatchResult {
        lock.lock()
        if let existing = registrations[identity] {
            lock.unlock()
            return existing.fence.hasExited ? .alreadyExited : .watching(existing.fence)
        }
        let fence = BackendOnlyRendererWorkerExitFence()
        let source = DispatchSource.makeProcessSource(
            identifier: identity.processID,
            eventMask: .exit,
            queue: queue
        )
        registrations[identity] = Registration(
            source: source,
            fence: fence,
            onExit: onExit
        )
        source.setEventHandler { [weak self] in
            self?.processExited(identity)
        }
        source.activate()
        lock.unlock()

        switch Self.currentProcessInstanceToken(processID: identity.processID) {
        case .exact(let token) where token == identity.processInstanceToken:
            return fence.hasExited ? .alreadyExited : .watching(fence)
        case .exact, .missing:
            cancel(identity)
            return .alreadyExited
        case .unverifiable:
            cancel(identity)
            return .unverifiable
        }
    }

    func cancel(_ identity: BackendOnlyRendererWorkerIdentity) {
        lock.lock()
        let registration = registrations.removeValue(forKey: identity)
        lock.unlock()
        registration?.source.cancel()
    }

    private func processExited(_ identity: BackendOnlyRendererWorkerIdentity) {
        lock.lock()
        let registration = registrations.removeValue(forKey: identity)
        lock.unlock()
        guard let registration else { return }
        registration.fence.finish()
        registration.source.cancel()
        registration.onExit(identity)
    }

    private static func currentProcessInstanceToken(processID: pid_t) -> ProcessLookup {
        var info = proc_bsdinfo()
        let expectedSize = MemoryLayout<proc_bsdinfo>.stride
        errno = 0
        let size = proc_pidinfo(
            processID,
            PROC_PIDTBSDINFO,
            0,
            &info,
            Int32(expectedSize)
        )
        if size == expectedSize, info.pbi_pid == UInt32(processID) {
            return .exact(BackendRendererProcessInstanceToken(
                startTimeSeconds: info.pbi_start_tvsec,
                startTimeMicroseconds: info.pbi_start_tvusec
            ))
        }
        if size <= 0, errno == ESRCH {
            return .missing
        }
        if size <= 0 {
            errno = 0
            if Darwin.kill(processID, 0) != 0, errno == ESRCH {
                return .missing
            }
        }
        return .unverifiable
    }

    deinit {
        lock.lock()
        let registrations = Array(registrations.values)
        self.registrations.removeAll()
        lock.unlock()
        for registration in registrations {
            registration.source.cancel()
        }
    }
}
