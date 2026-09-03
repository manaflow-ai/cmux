public import Foundation
import Observation
import OSLog

private nonisolated enum LocalLinuxBootResult: Sendable {
    case success(LocalLinuxSession)
    case failure(LocalLinuxError)
    case cancelled
}

/// A terminal surface's handle on the running shell.
///
/// The lane replays retained history and then streams live output. The
/// generation token must accompany every input byte so a surface that was
/// replaced during a retry cannot write into the replacement pty.
public struct LocalLinuxAttachment: Sendable {
    public let generation: UInt64
    public let lane: LocalLinuxTerminalLane

    fileprivate init(generation: UInt64, lane: LocalLinuxTerminalLane) {
        self.generation = generation
        self.lane = lane
    }
}

/// Owns the process-wide iSH session while one or more Ghostty surfaces attach
/// to it. A view attachment is transient; the session and bounded scrollback
/// survive navigation and window detachment so returning to the row restores
/// the recent shell output.
///
/// The controller alone decides when the shell has ended: it watches the
/// scrollback ring's source and fences the session on EOF. Surfaces only
/// attach, send input, resize, and detach.
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

    /// Bytes queued for the pty before a session exists or while the
    /// non-blocking tty is full. Beyond this, input is dropped and logged.
    public static let inputQueueLimit = 64 * 1024
    /// Grid used until Ghostty reports its first real size.
    public static let fallbackGrid = (columns: 80, rows: 24)
    /// Linux `EAGAIN`, represented as the negative errno returned by iSH's
    /// non-blocking tty bridge when its line buffer is full.
    private static let wouldBlockErrno: Int32 = -11

    private struct PendingGrid: Equatable, Sendable {
        let columns: Int
        let rows: Int
    }

    /// The injected actor that owns the process-global kernel configuration.
    @ObservationIgnored public let runtime: LocalLinuxRuntime
    /// How the shell is launched. Fixed for the controller's lifetime.
    @ObservationIgnored public let shell: LocalLinuxShellConfiguration
    @ObservationIgnored private var session: LocalLinuxSession?
    /// A session returned by the detached open task before its ring has been
    /// installed. Teardown must fence this handle too, otherwise a retry can
    /// start a second pty while the first install is still suspended.
    @ObservationIgnored private var pendingSession: LocalLinuxSession?
    @ObservationIgnored private var ring: LocalLinuxScrollbackRing?
    /// Awaits the ring's source EOF and records the natural session end.
    @ObservationIgnored private var sessionEndWatcher: Task<Void, Never>?
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
    /// The single input queue. Bytes typed before the pty exists wait here
    /// and are flushed by the worker once a session is installed.
    @ObservationIgnored private var inputQueue = LocalLinuxInputFIFO()
    @ObservationIgnored private var resizeTask: Task<Void, Never>?
    /// The latest grid reported by Ghostty, including while boot or pty open
    /// is still suspended. UIKit can report the real size before the local
    /// session exists, so dropping that report would leave the shell at the
    /// fallback grid until a later resize.
    @ObservationIgnored private var pendingGrid: PendingGrid?
    @ObservationIgnored private var lifecycleGeneration: UInt64 = 0
    @ObservationIgnored private var retryableFailure = false
    /// Input from an old Ghostty surface must not be queued while a session is
    /// being fenced. Admission reopens only after a replacement session owns
    /// the controller, so stale callbacks cannot cross a retry boundary.
    @ObservationIgnored private var acceptsInput = true

    public private(set) var state: State = .idle
    public private(set) var lastError: LocalLinuxError?

    public init(
        runtime: LocalLinuxRuntime,
        shell: LocalLinuxShellConfiguration = .default
    ) {
        self.runtime = runtime
        self.shell = shell
    }

    // MARK: Surface API

    /// Starts the shell if needed and returns an attachment for one surface.
    /// Returns `nil` when the shell could not start; `state` and `lastError`
    /// then describe why. The caller must `close()` the lane when its surface
    /// is dismantled.
    public func attach(columns: Int, rows: Int) async -> LocalLinuxAttachment? {
        guard await startIfNeeded(columns: columns, rows: rows) else { return nil }
        guard let session, let ring else { return nil }
        let generation = lifecycleGeneration
        let lane = LocalLinuxTerminalLane(
            source: session,
            ring: ring,
            cursor: nil,
            input: { [weak self] data in
                Task { @MainActor [weak self] in
                    self?.send(data, generation: generation)
                }
            }
        )
        return LocalLinuxAttachment(generation: generation, lane: lane)
    }

    /// Sends raw terminal bytes. Ghostty input includes control and escape
    /// sequences, so it must not be lossy-converted through `String` first.
    /// Use this before an attachment exists, for example for typeahead while
    /// the kernel boots; attached surfaces pass their generation instead.
    public func send(_ data: Data) {
        send(data, generation: lifecycleGeneration)
    }

    /// Sends bytes only when they belong to the controller generation that
    /// owns the current local pty.
    public func send(_ data: Data, generation: UInt64) {
        guard !data.isEmpty else { return }
        guard generation == lifecycleGeneration else {
            LocalLinuxLog.logger.debug(
                "ignoring local Linux input from stale generation \(generation, privacy: .public)"
            )
            return
        }
        guard acceptsInput else {
            LocalLinuxLog.logger.debug(
                "ignoring local Linux input while session admission is fenced"
            )
            return
        }
        let remaining = Self.inputQueueLimit - inputQueue.byteCount
        guard remaining > 0 else {
            LocalLinuxLog.logger.error(
                "local Linux input queue is full; dropping \(data.count, privacy: .public) bytes"
            )
            return
        }
        let bytes = Data(data.prefix(remaining))
        inputQueue.append(bytes)
        if bytes.count != data.count {
            LocalLinuxLog.logger.error(
                "local Linux input queue limit dropped \(data.count - bytes.count, privacy: .public) bytes"
            )
        }
        startInputWorkerIfNeeded()
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
                LocalLinuxLog.logger.error(
                    "local Linux resize failed: \(String(describing: error), privacy: .public)"
                )
            }
        }
    }

    // MARK: Lifecycle

    /// Starts the shell once and resizes an already-running shell to the latest
    /// Ghostty grid. The blocking kernel boot work runs off the main actor.
    @discardableResult
    public func startIfNeeded(
        columns: Int = fallbackGrid.columns,
        rows: Int = fallbackGrid.rows
    ) async -> Bool {
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
        let shell = shell
        let taskID = UUID()
        let task = Task { @MainActor [weak self, runtime, shell, generation, columns, rows, taskID] in
            let result = await Self.bootSession(
                runtime: runtime,
                shell: shell,
                columns: columns,
                rows: rows
            )
            guard let self else {
                if case let .success(session) = result {
                    await session.hangup()
                }
                return false
            }
            let installed = await self.install(result, generation: generation)
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

    /// Terminates the local shell. Navigation and scene detachment should not
    /// call this; use it only when the local computer is explicitly removed.
    public func terminate() {
        fenceLifecycle(into: .ended)
        pendingGrid = nil
    }

    /// Marks a renderer setup failure so the destination does not remain on a
    /// permanent loading overlay when Ghostty cannot create its surface.
    ///
    /// The controller outlives a terminal view, so this can happen after a
    /// healthy session was already running (for example, when a new surface
    /// cannot be created after navigation). Fence that session too. An ended
    /// controller ignores a stale callback from a dismantled view.
    public func markRendererFailure() {
        guard state != .ended, state != .failed else { return }
        // Renderer creation can fail while the detached boot/open task is
        // still producing a session. Fence that generation before publishing
        // the failure, otherwise its later install could resurrect a terminal
        // behind the error overlay.
        fenceLifecycle(into: .failed)
        lastError = .rendererUnavailable
        retryableFailure = true
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

    // MARK: Fencing

    /// Ends the current lifecycle generation: stops every task, schedules the
    /// C hangup for every session handle, discards queued input, and publishes
    /// `nextState`. Callers set `lastError` and `retryableFailure` afterwards.
    ///
    /// Every teardown path shares this method so the fence semantics cannot
    /// drift: a bumped generation rejects stale input and stale install
    /// results, and the close barrier makes the next startup wait for the
    /// detached hangup.
    private func fenceLifecycle(into nextState: State) {
        lifecycleGeneration &+= 1
        acceptsInput = false
        startTask?.cancel()
        sessionEndWatcher?.cancel()
        sessionEndWatcher = nil
        inputWorker?.cancel()
        inputWorker = nil
        inputWorkerID = nil
        resizeTask?.cancel()
        resizeTask = nil
        scheduleSessionClose(pendingSession)
        pendingSession = nil
        scheduleSessionClose(session)
        session = nil
        ring = nil
        inputQueue.removeAll(keepingCapacity: false)
        state = nextState
        retryableFailure = false
    }

    /// Records a natural pty exit for exactly the session that produced it.
    /// Lane detaches never reach this method, so navigating away keeps the
    /// shell alive and a later attachment can continue from the ring.
    private func sessionDidEnd(_ endedSession: LocalLinuxSession) {
        guard let session, session === endedSession else { return }
        fenceLifecycle(into: .ended)
    }

    /// Exposes an unrecoverable pty write error through the same visible
    /// failure state as boot errors. The failed pty is not safe to reuse, so
    /// its unsent FIFO is discarded before a retry creates a new shell. This
    /// avoids replaying a partial command into a replacement pty.
    private func markInputFailure(_ error: LocalLinuxError) {
        guard state != .ended else { return }
        fenceLifecycle(into: .failed)
        lastError = error
        retryableFailure = true
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
    /// Synchronous MainActor teardown cannot await the C bridge directly, but
    /// it still must leave a completion token for the next startup. Chaining
    /// keeps every released session alive until its own hangup has settled and
    /// gives `startIfNeeded()` one fence to await.
    private func scheduleSessionClose(_ candidate: LocalLinuxSession?) {
        guard let candidate else { return }
        let previous = closeBarrier
        let barrierID = UUID()
        // `beginClose()` is the nonisolated, nonblocking lifecycle seam. Start
        // the first close immediately so a synchronous renderer or input
        // failure cannot leave the pty waiting for a detached actor hop to be
        // scheduled. Keep later closes serialized because iSH teardown shares
        // process-global state.
        let task: Task<Void, Never>
        if let previous {
            task = Task.detached(priority: .utility) {
                await previous.value
                await candidate.beginClose().value
            }
        } else {
            task = candidate.beginClose()
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

    // MARK: Boot and install

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
        shell: LocalLinuxShellConfiguration,
        columns: Int,
        rows: Int
    ) async -> LocalLinuxBootResult {
        let worker = Task.detached(priority: .userInitiated) {
            do {
                try Task.checkCancellation()
                try await runtime.bootIfNeeded()
                try Task.checkCancellation()
                let session = try await runtime.openSession(
                    command: shell.command,
                    environment: shell.environment,
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
                LocalLinuxLog.logger.error(
                    "unexpected local Linux boot error: \(String(describing: error), privacy: .public)"
                )
                return LocalLinuxBootResult.failure(.operationFailed(String(describing: error)))
            }
        }

        return await withTaskCancellationHandler(operation: {
            await worker.value
        }, onCancel: {
            worker.cancel()
        })
    }

    private func install(_ result: LocalLinuxBootResult, generation: UInt64) async -> Bool {
        guard generation == lifecycleGeneration else {
            if case let .success(session) = result {
                await session.hangup()
            }
            return false
        }
        if session != nil {
            // A concurrent attachment already installed a shell for this
            // generation. Apply the newest grid and share it.
            applyPendingResizeIfRunning()
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
                LocalLinuxLog.logger.error(
                    "local Linux output retention failed: \(String(describing: error), privacy: .public)"
                )
                fenceLifecycle(into: .failed)
                lastError = .outputRetentionUnavailable
                return false
            }
            // A command can exit before the synchronous bridge returns from
            // openSession. Do not publish an already-ended handle as running,
            // or a first input callback could target a dead pty.
            guard !(await session.isEnded) else {
                await session.hangup()
                guard generation == lifecycleGeneration else { return false }
                fenceLifecycle(into: .ended)
                return false
            }
            // `isEnded` and `start(source:)` cross actors and can suspend this
            // MainActor continuation. Teardown or a concurrent attachment can
            // win while suspended, so revalidate ownership before installing.
            guard generation == lifecycleGeneration,
                  pendingSession === session,
                  self.session == nil else {
                await session.hangup()
                return false
            }
            self.session = session
            ring = newRing
            acceptsInput = true
            watchSessionEnd(session: session, ring: newRing, generation: generation)
            applyPendingResizeIfRunning()
            startInputWorkerIfNeeded()
            state = .running
            retryableFailure = false
            return true
        case let .failure(error):
            lastError = error
            state = .failed
            retryableFailure = Self.isRetryableSessionFailure(error)
            acceptsInput = false
            inputQueue.removeAll(keepingCapacity: false)
            LocalLinuxLog.logger.error(
                "local Linux boot failed: \(String(describing: error), privacy: .public)"
            )
            return false
        }
    }

    /// Learns about the shell's natural end from the ring, which is the sole
    /// consumer of the session's output stream. Lanes come and go with
    /// surfaces and therefore cannot tell EOF from their own detachment.
    private func watchSessionEnd(
        session: LocalLinuxSession,
        ring: LocalLinuxScrollbackRing,
        generation: UInt64
    ) {
        sessionEndWatcher?.cancel()
        sessionEndWatcher = Task { @MainActor [weak self, session, ring, generation] in
            var ended = ring.sourceEnded.makeAsyncIterator()
            _ = await ended.next()
            guard !Task.isCancelled, let self,
                  self.lifecycleGeneration == generation,
                  self.session === session else { return }
            // The ring finishes only after the source stream ended, which the
            // runtime does solely for a hung-up or exited pty. Confirm on the
            // session so a cancelled pump can never be misread as an exit.
            guard await session.isEnded else { return }
            guard self.lifecycleGeneration == generation,
                  self.session === session else { return }
            self.sessionDidEnd(session)
        }
    }

    // MARK: Input worker

    /// Serializes terminal input through one worker. Ghostty can emit one
    /// callback per keystroke, so a task chain per callback would retain a long
    /// linked list during a paste. This bounded FIFO preserves byte order with
    /// one cancellable task instead.
    private func startInputWorkerIfNeeded() {
        guard inputWorker == nil, !inputQueue.isEmpty else { return }
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
                            LocalLinuxLog.logger.error(
                                "local Linux input accepted invalid byte count \(accepted) of \(remainder.count)"
                            )
                            self.markInputFailure(.inputByteCountInvalid)
                            return
                        }
                        guard accepted > 0 else {
                            // The C shim uses zero for a full non-blocking tty
                            // buffer. Leave the remainder in place and wait
                            // for the next coalesced input-readiness edge.
                            LocalLinuxLog.logger.debug(
                                "local Linux input backpressured with \(remainder.count, privacy: .public) bytes pending"
                            )
                            waitForReadiness = true
                            break
                        }

                        consumedByteCount += accepted
                        self.inputQueue.consume(accepted)
                    }
                } catch {
                    // The send may resume after teardown has cancelled this
                    // worker and installed a replacement session. Never let
                    // that stale result classify the replacement pty as
                    // failed, and never publish an error after cancellation.
                    guard !Task.isCancelled,
                          self.inputWorkerID == workerID,
                          self.session === session else { return }
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
                        LocalLinuxLog.logger.debug(
                            "local Linux input backpressured with \(self.inputQueue.byteCount, privacy: .public) bytes pending"
                        )
                        waitForReadiness = true
                    } else {
                        LocalLinuxLog.logger.error(
                            "local Linux input failed: \(String(describing: error), privacy: .public)"
                        )
                        self.markInputFailure(
                            (error as? LocalLinuxError)
                                ?? .operationFailed(String(describing: error))
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

    // MARK: Grid

    private func rememberGrid(columns: Int, rows: Int) {
        pendingGrid = PendingGrid(columns: columns, rows: rows)
    }

    private func applyPendingResizeIfRunning() {
        guard session != nil, let grid = pendingGrid else { return }
        resize(columns: grid.columns, rows: grid.rows)
    }

    private static func isRetryableSessionFailure(_ error: LocalLinuxError) -> Bool {
        if case .sessionOpenFailed = error {
            return true
        }
        return false
    }
}
