public import Foundation
import Observation
import OSLog

nonisolated private let localLinuxProductionLog = Logger(
    subsystem: "dev.cmux.ios",
    category: "local-linux.production"
)

private nonisolated enum LocalLinuxBootResult: Sendable {
    case success(LocalLinuxSession)
    case failure(LocalLinuxError)
    case cancelled
}

/// Owns the process-wide iSH session while one or more Ghostty surfaces attach
/// to it. A view attachment is transient; the session and bounded scrollback
/// survive navigation and window detachment so returning to the row restores
/// the recent shell output.
@MainActor
@Observable
public final class LocalLinuxComputerController {
    public enum State: Equatable, Sendable {
        case idle
        case starting
        case running
        case ended
        case failed
    }

    private static let pendingInputLimit = 64 * 1024
    /// Linux `EAGAIN`, represented as the negative errno returned by iSH's
    /// non-blocking tty bridge when its line buffer is full.
    private static let wouldBlockErrno: Int32 = -11

    private struct PendingGrid: Equatable, Sendable {
        let columns: Int
        let rows: Int
    }

    /// The injected actor that owns the process-global kernel configuration.
    /// Exposed so DEBUG harnesses can use the same instance as production.
    @ObservationIgnored public let runtime: LocalLinuxRuntime
    @ObservationIgnored private var session: LocalLinuxSession?
    /// A session returned by the detached open task before its ring has been
    /// installed. Teardown must fence this handle too, otherwise a retry can
    /// start a second pty while the first install is still suspended.
    @ObservationIgnored private var pendingSession: LocalLinuxSession?
    @ObservationIgnored private var ring: LocalLinuxScrollbackRing?
    /// One shared startup operation per lifecycle generation. Multiple terminal
    /// surfaces can ask to start at the same time; they must all await this
    /// task instead of each installing a competing ring over one PTY stream.
    @ObservationIgnored private var startTask: Task<Bool, Never>?
    @ObservationIgnored private var startTaskGeneration: UInt64?
    /// Identity for the startup task retained as a cancellation barrier. The
    /// generation alone is not enough when a stale task finishes during a
    /// later retry.
    @ObservationIgnored private var startTaskID: UUID?
    /// Completion fence for sessions released by synchronous lifecycle
    /// callbacks. The fence is intentionally retained after ownership is
    /// cleared, so a retry cannot open a new C pty while the old hangup is
    /// still settling on its detached worker.
    @ObservationIgnored private var closeBarrier: Task<Void, Never>?
    @ObservationIgnored private var closeBarrierID: UUID?
    @ObservationIgnored private var inputWorker: Task<Void, Never>?
    @ObservationIgnored private var inputWorkerID: UUID?
    @ObservationIgnored private var inputQueue = LocalLinuxInputFIFO()
    @ObservationIgnored private var resizeTask: Task<Void, Never>?
    /// The latest grid reported by Ghostty, including while boot or pty open
    /// is still suspended. UIKit can report the real size before the local
    /// session exists, so dropping that report would leave the shell at the
    /// 80x24 fallback until a later resize.
    @ObservationIgnored private var pendingGrid: PendingGrid?
    @ObservationIgnored private var pendingInput = Data()
    @ObservationIgnored private var lifecycleGeneration: UInt64 = 0
    @ObservationIgnored private var retryableFailure = false
    /// Input from an old Ghostty surface must not be queued while a session is
    /// being fenced. Admission reopens only after a replacement session owns
    /// the controller, so stale callbacks cannot cross a retry boundary.
    @ObservationIgnored private var acceptsInput = true

    public private(set) var state: State = .idle
    public private(set) var lastError: LocalLinuxError?

    public init(runtime: LocalLinuxRuntime) {
        self.runtime = runtime
    }

    /// Starts the shell once and resizes an already-running shell to the latest
    /// Ghostty grid. The blocking kernel boot work runs off the main actor.
    @discardableResult
    public func startIfNeeded(columns: Int = 80, rows: Int = 24) async -> Bool {
        let columns = max(1, columns)
        let rows = max(1, rows)
        rememberGrid(columns: columns, rows: rows)

        // Boot failures are intentionally sticky for this controller and its
        // injected runtime. Re-entering the destination must not repeatedly
        // mutate a partially initialized process or present a misleading
        // retry action. Renderer and input failures are reset explicitly by
        // the retry button after their old session has been fenced.
        if state == .failed {
            return false
        }

        // A cancelled startup can still be inside the synchronous C open.
        // Retain and await that task before creating another one. Awaiting a
        // task suspends the main actor, so UI event handling remains
        // responsive while the old worker settles.
        await waitForCancelledStartup()
        // A cancelled or failed lifecycle may also have released a session
        // whose C hangup is still running on a detached worker. Do not begin
        // another open until that completion fence has settled.
        await waitForSessionCloseBarrier()

        if state == .failed {
            return false
        }

        // `session.isEnded` suspends the MainActor. Teardown can replace or
        // clear the session while that actor hop is suspended, so revalidate
        // both identity and generation before touching the controller state.
        // Looping also handles a replacement that was installed before this
        // continuation resumed, avoiding a second competing pty.
        while let candidate = session {
            let observedGeneration = lifecycleGeneration
            let ended = await candidate.isEnded
            guard observedGeneration == lifecycleGeneration,
                  self.session === candidate else {
                continue
            }

            // A natural process exit finishes the session's output stream but
            // leaves the actor object retained by the controller. Clear that
            // ended attachment before deciding whether a new boot is needed.
            if ended {
                sessionDidEnd(candidate)
                continue
            }

            resize(columns: columns, rows: rows)
            state = .running
            return true
        }

        // A teardown may have scheduled a close while the session check was
        // suspended. Await its detached C fence before opening a replacement.
        await waitForSessionCloseBarrier()

        if state == .failed {
            return false
        }

        let generation = lifecycleGeneration
        if let startTask, startTaskGeneration == generation {
            let ready = await startTask.value
            // Termination can win while this waiter is suspended. Do not
            // report a successful startup to the stale coordinator after its
            // generation has been fenced.
            guard generation == lifecycleGeneration else { return false }
            // A resize callback may have arrived while the shared startup
            // task was importing the rootfs or opening the pty. The install
            // path applies the latest grid too, and this second application
            // closes the small window after install but before this waiter
            // resumes.
            if ready {
                applyPendingResizeIfRunning()
            }
            return ready
        }

        state = .starting
        lastError = nil
        retryableFailure = false
        let runtime = runtime
        let taskID = UUID()
        let task = Task { @MainActor [weak self, runtime, generation, columns, rows, taskID] in
            let result = await Self.bootSession(
                runtime: runtime,
                columns: columns,
                rows: rows
            )
            guard let self else {
                if case let .success(session) = result {
                    await session.hangup()
                }
                return false
            }
            let installed = await self.install(
                result,
                columns: columns,
                rows: rows,
                generation: generation
            )
            // Keep the cancellation barrier until this exact operation has
            // settled. The identity check prevents an old task from clearing
            // a replacement task if lifecycle state changed while this
            // closure was suspended in `bootSession` or `install`.
            if self.startTaskID == taskID {
                self.startTask = nil
                self.startTaskGeneration = nil
                self.startTaskID = nil
            }
            return installed
        }
        startTask = task
        startTaskGeneration = generation
        startTaskID = taskID
        return await task.value
    }

    /// Waits for a startup task from an older lifecycle generation. The task
    /// remains stored after cancellation because `bootSession` may be waiting
    /// for a synchronous C open. Repeated termination calls are handled by the
    /// loop, and the metadata fallback repairs an incomplete task assignment.
    private func waitForCancelledStartup() async {
        while let task = startTask {
            guard let taskGeneration = startTaskGeneration else {
                startTask = nil
                startTaskGeneration = nil
                startTaskID = nil
                return
            }
            guard taskGeneration != lifecycleGeneration else { return }

            let taskID = startTaskID
            _ = await task.value

            // The startup task normally clears these fields itself. Keep this
            // fallback for a cancellation race between install and cleanup.
            if startTaskID == taskID {
                startTask = nil
                startTaskGeneration = nil
                startTaskID = nil
            }
        }
    }

    /// Starts a nonblocking close and chains it behind any earlier close.
    ///
    /// `terminate()` and renderer/input failure callbacks are synchronous
    /// MainActor methods. They cannot await the C bridge directly, but they
    /// still must leave a completion token for the next startup. Chaining
    /// keeps every released session alive until its own hangup has settled and
    /// gives `startIfNeeded()` one fence to await.
    private func scheduleSessionClose(_ candidate: LocalLinuxSession?) {
        guard let candidate else { return }
        let previous = closeBarrier
        let barrierID = UUID()
        let task = Task.detached(priority: .utility) {
            if let previous {
                await previous.value
            }
            await candidate.hangup()
        }
        closeBarrier = task
        closeBarrierID = barrierID
    }

    /// Waits for all session closes scheduled by an earlier lifecycle
    /// generation. MainActor reentrancy can install another barrier while the
    /// current one is suspended, so clear metadata only when its identity is
    /// still current.
    private func waitForSessionCloseBarrier() async {
        while let barrier = closeBarrier {
            let barrierID = closeBarrierID
            await barrier.value
            guard closeBarrierID == barrierID else { continue }
            closeBarrier = nil
            closeBarrierID = nil
        }
    }

    /// Runs the blocking iSH boot and pty creation off the main actor. The
    /// cancellation handler forwards controller teardown to the worker, and a
    /// session opened in the cancellation race is asynchronously fenced before
    /// this helper returns.
#if compiler(>=6.2)
    @concurrent
#else
    @Sendable
#endif
    private nonisolated static func bootSession(
        runtime: LocalLinuxRuntime,
        columns: Int,
        rows: Int
    ) async -> LocalLinuxBootResult {
        let worker = Task.detached(priority: .userInitiated) {
            do {
                try Task.checkCancellation()
                try await runtime.bootIfNeeded()
                try Task.checkCancellation()
                let session = try await runtime.openSession(
                    columns: columns,
                    rows: rows
                )
                guard !Task.isCancelled else {
                    await session.hangup()
                    return LocalLinuxBootResult.cancelled
                }
                return LocalLinuxBootResult.success(session)
            } catch is CancellationError {
                return LocalLinuxBootResult.cancelled
            } catch let error as LocalLinuxError {
                return LocalLinuxBootResult.failure(error)
            } catch {
                localLinuxProductionLog.error(
                    "unexpected local Linux boot error: \(String(describing: error), privacy: .public)"
                )
                return LocalLinuxBootResult.failure(.sessionOpenFailed(errno: -1))
            }
        }

        return await withTaskCancellationHandler(operation: {
            await worker.value
        }, onCancel: {
            worker.cancel()
        })
    }

    /// Creates a lane attachment over the retained shell and output ring.
    /// Callers must close the lane when their Ghostty surface is dismantled.
    public func makeLane() -> LocalLinuxTerminalLane? {
        guard let session, let ring else { return nil }
        return LocalLinuxTerminalLane(session: session, ring: ring, cursor: nil)
    }

    /// The session paired with the most recent lane attachment. Coordinators
    /// pass this identity back on natural EOF so a stale lane cannot clear a
    /// newer shell that started while the old output task was unwinding.
    public var currentSession: LocalLinuxSession? {
        session
    }

    /// Generation token for a Ghostty attachment. A coordinator must pass it
    /// with input so callbacks from a replaced surface cannot write to a new
    /// pty, even after input admission reopens.
    public var currentInputGeneration: UInt64 {
        lifecycleGeneration
    }

    /// Sends raw terminal bytes. Ghostty input includes control and escape
    /// sequences, so it must not be lossy-converted through `String` first.
    public func send(_ data: Data) {
        send(data, generation: lifecycleGeneration)
    }

    /// Sends bytes only when they belong to the controller generation that
    /// owns the current local pty. This overload is the boundary used by
    /// Ghostty coordinators; the unlabeled form remains for trusted callers.
    public func send(_ data: Data, generation: UInt64) {
        guard !data.isEmpty else { return }
        guard generation == lifecycleGeneration else {
            localLinuxProductionLog.debug(
                "ignoring local Linux input from stale generation \(generation, privacy: .public)"
            )
            return
        }
        guard acceptsInput else {
            localLinuxProductionLog.debug(
                "ignoring local Linux input while session admission is fenced"
            )
            return
        }
        if session != nil {
            let remaining = Self.pendingInputLimit - inputQueue.byteCount
            guard remaining > 0 else {
                localLinuxProductionLog.error(
                    "local Linux input queue is full; dropping \(data.count, privacy: .public) bytes"
                )
                return
            }
            let bytes = Data(data.prefix(remaining))
            inputQueue.append(bytes)
            if bytes.count != data.count {
                localLinuxProductionLog.error(
                    "local Linux input queue limit dropped \(data.count - bytes.count, privacy: .public) bytes"
                )
            }
            startInputWorkerIfNeeded()
            return
        }

        let remaining = Self.pendingInputLimit - pendingInput.count
        guard remaining > 0 else {
            localLinuxProductionLog.error(
                "local Linux pending input queue is full; dropping \(data.count, privacy: .public) bytes"
            )
            return
        }
        let bytes = Data(data.prefix(remaining))
        pendingInput.append(bytes)
        if bytes.count != data.count {
            localLinuxProductionLog.error(
                "local Linux pending input limit dropped \(data.count - bytes.count, privacy: .public) bytes"
            )
        }
    }

    /// Gives a blocked input write a fallback retry signal. Production iSH
    /// sessions signal their readiness stream directly; this path remains for
    /// older bridges that only expose output activity.
    public func notifyOutputActivity() {
        guard !inputQueue.isEmpty, let session else { return }
        session.signalInputReady()
    }

    public func resize(columns: Int, rows: Int) {
        guard columns > 0, rows > 0 else { return }
        rememberGrid(columns: columns, rows: rows)
        guard let session else { return }
        let generation = lifecycleGeneration
        resizeTask?.cancel()
        resizeTask = Task { @MainActor [weak self, session] in
            guard let self,
                  self.lifecycleGeneration == generation,
                  self.session === session else { return }
            do {
                try await session.resize(columns: columns, rows: rows)
            } catch {
                guard self.lifecycleGeneration == generation,
                      self.session === session else { return }
                localLinuxProductionLog.error(
                    "local Linux resize failed: \(String(describing: error), privacy: .public)"
                )
            }
        }
    }

    /// Terminates the local shell. Navigation and scene detachment should not
    /// call this; use it only when the local computer is explicitly removed.
    public func terminate() {
        lifecycleGeneration &+= 1
        acceptsInput = false
        startTask?.cancel()
        inputWorker?.cancel()
        inputWorker = nil
        inputWorkerID = nil
        inputQueue.removeAll(keepingCapacity: false)
        resizeTask?.cancel()
        resizeTask = nil
        scheduleSessionClose(pendingSession)
        pendingSession = nil
        scheduleSessionClose(session)
        session = nil
        ring = nil
        pendingGrid = nil
        pendingInput.removeAll(keepingCapacity: false)
        state = .ended
        retryableFailure = false
    }

    /// Records a natural pty exit for exactly the session that produced it.
    /// Lane detaches do not call this method, so navigating away keeps the
    /// shell alive and a later attachment can continue from the ring.
    public func sessionDidEnd(_ endedSession: LocalLinuxSession) {
        guard let session, session === endedSession else { return }
        // Natural EOF and ingress overflow can both race a replacement boot.
        // Start a completion fence for the exact handle before clearing
        // ownership. The C bridge hangup is idempotent, and the next startup
        // awaits the fence so deferred cleanup cannot survive into a new
        // shell.
        acceptsInput = false
        scheduleSessionClose(endedSession)
        lifecycleGeneration &+= 1
        startTask?.cancel()
        inputWorker?.cancel()
        inputWorker = nil
        inputWorkerID = nil
        inputQueue.removeAll(keepingCapacity: false)
        resizeTask?.cancel()
        resizeTask = nil
        self.session = nil
        ring = nil
        pendingInput.removeAll(keepingCapacity: false)
        state = .ended
        retryableFailure = false
    }

    private func install(
        _ result: LocalLinuxBootResult,
        columns: Int,
        rows: Int,
        generation: UInt64
    ) async -> Bool {
        guard generation == lifecycleGeneration else {
            if case let .success(session) = result {
                await session.hangup()
            }
            return false
        }
        if let session {
            resizeTask?.cancel()
            let resizeGeneration = lifecycleGeneration
            resizeTask = Task { @MainActor [weak self, session] in
                guard let self,
                      self.lifecycleGeneration == resizeGeneration,
                      self.session === session else { return }
                try? await session.resize(columns: columns, rows: rows)
            }
            state = .running
            return true
        }

        switch result {
        case .cancelled:
            return false
        case let .success(session):
            pendingSession = session
            defer {
                if pendingSession === session {
                    pendingSession = nil
                }
            }
            guard generation == lifecycleGeneration else {
                await session.hangup()
                return false
            }
            let newRing = LocalLinuxScrollbackRing()
            do {
                // Start the sole output consumer before publishing the session.
                // This drains the runtime's bounded ingress into a fixed-size
                // replay ring immediately, including while the app is inactive
                // or no Ghostty view is mounted.
                try await newRing.start(source: session)
            } catch {
                await session.hangup()
                guard generation == lifecycleGeneration else { return false }
                acceptsInput = false
                pendingInput.removeAll(keepingCapacity: false)
                let localError = LocalLinuxError.operationFailed(
                    "terminal output retention could not start"
                )
                lastError = localError
                state = .failed
                localLinuxProductionLog.error(
                    "local Linux output retention failed: \(String(describing: error), privacy: .public)"
                )
                return false
            }
            // A command can exit before the synchronous bridge returns from
            // openSession. Do not publish an already-ended handle as running,
            // or a first input callback could target a dead pty.
            guard !(await session.isEnded) else {
                await session.hangup()
                guard generation == lifecycleGeneration else { return false }
                lifecycleGeneration &+= 1
                acceptsInput = false
                pendingInput.removeAll(keepingCapacity: false)
                state = .ended
                retryableFailure = false
                return false
            }
            // `isEnded` is actor-isolated and can suspend this MainActor
            // continuation. A concurrent attachment must not replace the
            // controller's session while this candidate is being inspected.
            guard generation == lifecycleGeneration,
                  pendingSession === session,
                  self.session == nil else {
                await session.hangup()
                return false
            }
            // `start(source:)` crosses the ring actor. Teardown can win while
            // it is suspended, so revalidate ownership before installing.
            guard generation == lifecycleGeneration else {
                await session.hangup()
                return false
            }
            self.session = session
            ring = newRing
            acceptsInput = true
            let grid = pendingGrid ?? PendingGrid(columns: columns, rows: rows)
            resize(columns: grid.columns, rows: grid.rows)
            if !pendingInput.isEmpty {
                let bytes = pendingInput
                pendingInput.removeAll(keepingCapacity: false)
                send(bytes)
            }
            state = .running
            retryableFailure = false
            return true
        case let .failure(error):
            lastError = error
            state = .failed
            retryableFailure = Self.isRetryableSessionFailure(error)
            acceptsInput = false
            pendingInput.removeAll(keepingCapacity: false)
            localLinuxProductionLog.error(
                "local Linux boot failed: \(String(describing: error), privacy: .public)"
            )
            return false
        }
    }

    /// Serializes terminal input through one worker. Ghostty can emit one
    /// callback per keystroke, so a task chain per callback would retain a long
    /// linked list during a paste. This bounded FIFO preserves byte order with
    /// one cancellable task instead.
    private func startInputWorkerIfNeeded() {
        guard inputWorker == nil else { return }
        guard let workerSession = session else { return }
        let workerID = UUID()
        inputWorkerID = workerID
        inputWorker = Task { @MainActor [weak self, workerID, workerSession] in
            guard let self else { return }
            defer {
                if self.inputWorkerID == workerID {
                    self.inputWorkerID = nil
                    self.inputWorker = nil
                }
            }

            // Keep one iterator for the worker's entire lifetime. The
            // bufferingNewest(1) stream preserves an edge that arrives between
            // a zero-byte write and this await, so no polling or timer is
            // needed.
            let readiness = workerSession.inputReady
            var readinessIterator = readiness.makeAsyncIterator()

            while !Task.isCancelled,
                  self.inputWorkerID == workerID,
                  self.session === workerSession,
                  !self.inputQueue.isEmpty {
                let session = workerSession
                // Keep the current element in the FIFO while it is being
                // written. This preserves the exact remainder when the
                // non-blocking tty reports EAGAIN (zero accepted bytes).
                let headByteCount = self.inputQueue.headByteCount
                var consumedByteCount = 0
                var waitForReadiness = false

                do {
                    while consumedByteCount < headByteCount, !Task.isCancelled {
                        guard self.inputWorkerID == workerID,
                              self.session === session else { return }
                        // The FIFO returns a shared Data slice. Avoid
                        // rebuilding the remainder on every short write.
                        let remainder = self.inputQueue.headRemainder
                        let accepted = try await session.send(remainder)
                        guard self.inputWorkerID == workerID,
                              self.session === session else { return }

                        guard accepted >= 0, accepted <= remainder.count else {
                            // Keep the unsent remainder. A malformed bridge
                            // result is a backpressure boundary, not permission
                            // to lose terminal input.
                            localLinuxProductionLog.error(
                                "local Linux input accepted invalid byte count \(accepted) of \(remainder.count)"
                            )
                            self.markInputFailure(
                                .operationFailed("terminal input returned an invalid byte count")
                            )
                            return
                        }
                        guard accepted > 0 else {
                            // The C shim uses zero for a full non-blocking tty
                            // buffer. Leave the remainder in place and wait
                            // for the next coalesced input-readiness edge.
                            localLinuxProductionLog.debug(
                                "local Linux input backpressured with \(remainder.count, privacy: .public) bytes pending"
                            )
                            waitForReadiness = true
                            break
                        }

                        consumedByteCount += accepted
                        self.inputQueue.consume(accepted)
                    }
                } catch {
                    // `closed` is expected during teardown. Keep the
                    // remainder until the failure boundary decides whether
                    // the pty is still usable.
                    if let error = error as? LocalLinuxError, error == .closed {
                        return
                    }
                    // iSH's non-blocking tty API reports a full line buffer as
                    // -EAGAIN. This is temporary backpressure, not a broken
                    // shell. Keep the FIFO head and await the readiness stream.
                    if case let LocalLinuxError.inputFailed(errno) = error,
                       errno == Self.wouldBlockErrno {
                        localLinuxProductionLog.debug(
                            "local Linux input backpressured with \(self.inputQueue.byteCount, privacy: .public) bytes pending"
                        )
                        waitForReadiness = true
                    } else {
                        localLinuxProductionLog.error(
                            "local Linux input failed: \(String(describing: error), privacy: .public)"
                        )
                        self.markInputFailure(
                            (error as? LocalLinuxError)
                                ?? .operationFailed("terminal input failed")
                        )
                        return
                    }
                }

                guard self.inputWorkerID == workerID,
                      self.session === session else { return }
                if waitForReadiness {
                    guard await readinessIterator.next() != nil else { return }
                    guard !Task.isCancelled,
                          self.inputWorkerID == workerID,
                          self.session === session else { return }
                }
            }
        }
    }

    private func rememberGrid(columns: Int, rows: Int) {
        pendingGrid = PendingGrid(columns: columns, rows: rows)
    }

    private func applyPendingResizeIfRunning() {
        guard self.session != nil, let grid = pendingGrid else { return }
        resize(columns: grid.columns, rows: grid.rows)
    }

    /// Marks a renderer setup failure so the destination does not remain on a
    /// permanent loading overlay when Ghostty cannot create its surface.
    public func markRendererFailure() {
        guard state != .running else { return }
        // Renderer creation can fail while the detached boot/open task is
        // still producing a session. Fence that generation before publishing
        // the failure, otherwise its later install could resurrect a terminal
        // behind the error overlay.
        lifecycleGeneration &+= 1
        startTask?.cancel()
        inputWorker?.cancel()
        inputWorker = nil
        inputWorkerID = nil
        resizeTask?.cancel()
        resizeTask = nil
        acceptsInput = false
        scheduleSessionClose(pendingSession)
        pendingSession = nil
        scheduleSessionClose(session)
        session = nil
        ring = nil
        inputQueue.removeAll(keepingCapacity: false)
        pendingInput.removeAll(keepingCapacity: false)
        state = .failed
        lastError = .operationFailed("terminal renderer unavailable")
        retryableFailure = true
    }

    /// Exposes an unrecoverable pty write error through the same visible
    /// failure state as boot errors. The failed pty is not safe to reuse, so
    /// its unsent FIFO is discarded explicitly before a retry creates a new
    /// shell. This avoids replaying a partial command into a replacement pty.
    private func markInputFailure(_ error: LocalLinuxError) {
        guard state != .ended else { return }
        // A non-EAGAIN write failure invalidates the current pty. Keep no live
        // worker or ring behind the error overlay, and block callbacks from
        // the old surface until the user explicitly retries.
        acceptsInput = false
        lifecycleGeneration &+= 1
        inputWorker?.cancel()
        inputWorker = nil
        inputWorkerID = nil
        resizeTask?.cancel()
        resizeTask = nil
        let failedSession = session
        scheduleSessionClose(failedSession)
        session = nil
        ring = nil
        inputQueue.removeAll(keepingCapacity: false)
        pendingInput.removeAll(keepingCapacity: false)
        state = .failed
        lastError = error
        retryableFailure = true
    }

    private static func isRetryableSessionFailure(_ error: LocalLinuxError) -> Bool {
        if case .sessionOpenFailed = error {
            return true
        }
        return false
    }

    /// Whether the current failure can be reset without rebuilding the
    /// process-global kernel. Boot and rootfs failures stay sticky; renderer
    /// and session-input failures can safely start a fresh pty.
    public var canRetry: Bool {
        state == .ended || (state == .failed && retryableFailure)
    }

    /// Fences a retryable failure before the SwiftUI surface is recreated.
    public func prepareForRetry() {
        guard canRetry else { return }
        terminate()
        state = .idle
        lastError = nil
    }
}
