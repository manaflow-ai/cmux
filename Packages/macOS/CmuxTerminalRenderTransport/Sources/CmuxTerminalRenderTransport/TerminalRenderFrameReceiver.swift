public import CmuxTerminalRenderProtocol
internal import Dispatch
internal import Foundation
internal import IOSurface
internal import TerminalRenderMachIPC

/// Swift-owned receiver that authenticates and imports only current frames.
public actor TerminalRenderFrameReceiver {
    /// Maximum cancellable deadline for one receive operation.
    public static let maximumReceiveTimeoutMilliseconds: UInt32 = 250

    /// Private endpoint that must be handed only to the expected renderer worker.
    public nonisolated let endpoint: TerminalRenderFrameEndpoint

    private var receivePort: UInt32
    private var expectedWorker: TerminalRenderWorkerIdentity?
    private var fence: TerminalRenderPresentationFence
    private var acceptance = TerminalRenderFrameAcceptance()
    private let codec = TerminalRenderFrameMetadataCodec()
    // Mach receive readiness has no async-native source; DispatchSource only delivers events.
    private let receiveSource: any DispatchSourceMachReceive
    private var readinessWaiter: CheckedContinuation<TerminalRenderReceiveWake, Never>?
    private var readinessTimeoutTask: Task<Void, Never>?
    private var readinessToken: UInt64 = 0
    private var readyPending = false
    private var receiveInFlight = false
    private var stopped = false

    /// Creates a capability-scoped, bounded receive queue for one renderer worker.
    ///
    /// - Parameters:
    ///   - expectedWorker: PID and effective UID required in the Mach audit trailer.
    ///     Pass `nil` when the worker has not launched yet, then call ``authorize(worker:)``
    ///     with the `Process.processIdentifier` before receiving a frame.
    ///   - initialFence: Exact presentation generation and dimensions initially accepted.
    ///   - queueLimit: Kernel message queue depth from 1 through 64; defaults to 3.
    /// - Throws: ``TerminalRenderFrameTransportError`` when secure setup fails.
    public init(
        expectedWorker: TerminalRenderWorkerIdentity? = nil,
        initialFence: TerminalRenderPresentationFence,
        queueLimit: UInt32 = 3
    ) throws {
        guard Int(CMUX_TERMINAL_RENDER_CAPABILITY_LENGTH)
                == TerminalRenderFrameProtocol.capabilityLength,
              Int(CMUX_TERMINAL_RENDER_METADATA_LENGTH)
                == TerminalRenderFrameProtocol.metadataLength else {
            throw TerminalRenderFrameTransportError.bridgeContractMismatch
        }
        guard queueLimit > 0,
              queueLimit <= UInt32(CMUX_TERMINAL_RENDER_MAXIMUM_QUEUE_LIMIT) else {
            throw TerminalRenderFrameTransportError.invalidQueueLimit
        }
        let endpoint = try TerminalRenderFrameEndpointFactory().makeEndpoint()
        var port = mach_port_t(MACH_PORT_NULL)
        var machError: kern_return_t = KERN_SUCCESS
        let status = endpoint.serviceName.withCString {
            cmux_terminal_render_receiver_create($0, queueLimit, &port, &machError)
        }
        guard status == CMUX_TERMINAL_RENDER_STATUS_SUCCESS else {
            throw TerminalRenderFrameTransportError.receiverCreationFailed(machError)
        }
        let receiveQueue = DispatchQueue(
            label: "dev.cmux.terminal-render-frame-ready",
            qos: .userInteractive
        )
        let receiveSource = DispatchSource.makeMachReceiveSource(
            port: port,
            queue: receiveQueue
        )
        self.endpoint = endpoint
        self.expectedWorker = expectedWorker
        self.fence = initialFence
        self.receivePort = port
        self.receiveSource = receiveSource
        receiveSource.setEventHandler { [weak self] in
            Task {
                await self?.signalReadiness()
            }
        }
        receiveSource.resume()
    }

    deinit {
        receiveSource.cancel()
        readinessTimeoutTask?.cancel()
        if receivePort != UInt32(MACH_PORT_NULL) {
            cmux_terminal_render_receiver_destroy(receivePort)
        }
    }

    /// Replaces the accepted presentation generation and resets latest-frame state.
    ///
    /// Messages already in the Mach queue are evaluated against this new fence
    /// and discarded before IOSurface import when stale.
    ///
    /// - Parameter fence: New exact presentation and terminal expectations.
    public func updateFence(_ fence: TerminalRenderPresentationFence) {
        self.fence = fence
        acceptance = TerminalRenderFrameAcceptance()
    }

    /// Binds the endpoint capability to one kernel audit identity.
    ///
    /// Authorization is write-once for this receiver lifetime. A renderer
    /// restart must create a new receiver and capability so stale workers
    /// cannot reattach through PID reuse.
    ///
    /// - Parameter worker: PID and effective UID captured after worker launch.
    /// - Throws: ``TerminalRenderFrameTransportError/workerAlreadyAuthorized``
    ///   when a different identity was already installed.
    public func authorize(worker: TerminalRenderWorkerIdentity) throws {
        if let expectedWorker {
            guard expectedWorker == worker else {
                throw TerminalRenderFrameTransportError.workerAlreadyAuthorized
            }
            return
        }
        expectedWorker = worker
    }

    /// Returns the write-once worker identity currently authorized to send frames.
    public func authorizedWorker() -> TerminalRenderWorkerIdentity? {
        expectedWorker
    }

    /// Receives, authenticates, generation-checks, and conditionally imports one frame.
    ///
    /// A Mach dispatch source supplies readiness without blocking a cooperative
    /// executor. The actor then performs a nonblocking receive. Cancellation
    /// resumes the pending continuation and releases any received surface right.
    ///
    /// - Parameter timeoutMilliseconds: Kernel wait from 0 through 250 milliseconds.
    /// - Returns: A frame, a timeout, or a consumed drop reason.
    /// - Throws: ``CancellationError`` or ``TerminalRenderFrameTransportError``.
    public func receive(
        timeoutMilliseconds: UInt32 = 50
    ) async throws -> TerminalRenderFrameReceiveResult {
        return try await receive(
            timeoutMilliseconds: timeoutMilliseconds,
            expectedWorker: expectedWorker,
            allowQuiescedPeer: false
        )
    }

    private func receive(
        timeoutMilliseconds: UInt32,
        expectedWorker: TerminalRenderWorkerIdentity?,
        allowQuiescedPeer: Bool
    ) async throws -> TerminalRenderFrameReceiveResult {
        guard !stopped else {
            throw TerminalRenderFrameTransportError.stopped
        }
        guard timeoutMilliseconds <= Self.maximumReceiveTimeoutMilliseconds else {
            throw TerminalRenderFrameTransportError.invalidReceiveTimeout
        }
        guard !receiveInFlight else {
            throw TerminalRenderFrameTransportError.receiveAlreadyInProgress
        }
        let operation: TerminalRenderMachReceiverOperation
        if let expectedWorker {
            operation = TerminalRenderMachReceiverOperation(
                receivePort: receivePort,
                capability: endpoint.capability,
                expectedWorker: expectedWorker
            )
        } else {
            guard allowQuiescedPeer else {
                throw TerminalRenderFrameTransportError.workerNotAuthorized
            }
            operation = TerminalRenderMachReceiverOperation(
                quiescedReceivePort: receivePort,
                capability: endpoint.capability
            )
        }
        receiveInFlight = true
        defer { receiveInFlight = false }

        var rawResult = operation.run(timeoutMilliseconds: 0)
        if rawResult.status == CMUX_TERMINAL_RENDER_STATUS_TIMED_OUT.rawValue,
           timeoutMilliseconds > 0 {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(
                by: .milliseconds(Int64(timeoutMilliseconds))
            )
            while rawResult.status == CMUX_TERMINAL_RENDER_STATUS_TIMED_OUT.rawValue,
                  clock.now < deadline {
                let wake = await waitForReadiness(until: deadline, clock: clock)
                if wake == .cancelled || Task.isCancelled {
                    throw CancellationError()
                }
                if wake == .stopped || stopped {
                    throw TerminalRenderFrameTransportError.stopped
                }
                if wake == .timedOut {
                    return .timedOut
                }
                rawResult = operation.run(timeoutMilliseconds: 0)
            }
        }

        if Task.isCancelled {
            Self.releaseSurfaceRight(rawResult.surfacePort)
            throw CancellationError()
        }
        if stopped {
            Self.releaseSurfaceRight(rawResult.surfacePort)
            throw TerminalRenderFrameTransportError.stopped
        }

        switch rawResult.status {
        case CMUX_TERMINAL_RENDER_STATUS_TIMED_OUT.rawValue:
            return .timedOut
        case CMUX_TERMINAL_RENDER_STATUS_INVALID_MESSAGE.rawValue:
            return .dropped(.malformedMachMessage, release: nil)
        case CMUX_TERMINAL_RENDER_STATUS_CAPABILITY_MISMATCH.rawValue:
            return .dropped(.capabilityMismatch, release: nil)
        case CMUX_TERMINAL_RENDER_STATUS_PEER_MISMATCH.rawValue:
            return .dropped(.peerIdentityMismatch, release: nil)
        case CMUX_TERMINAL_RENDER_STATUS_SUCCESS.rawValue:
            break
        default:
            throw TerminalRenderFrameTransportError.receiveFailed(rawResult.machError)
        }

        guard let encodedMetadata = rawResult.metadata else {
            Self.releaseSurfaceRight(rawResult.surfacePort)
            return .dropped(.malformedMachMessage, release: nil)
        }
        let metadata: TerminalRenderFrameMetadata
        do {
            metadata = try codec.decode(encodedMetadata)
        } catch let error as TerminalRenderFrameProtocolError {
            Self.releaseSurfaceRight(rawResult.surfacePort)
            return .dropped(.malformedMetadata(error), release: nil)
        }

        var tentativeAcceptance = acceptance
        let rejection = tentativeAcceptance.accept(metadata, against: fence)

        guard let importedSurface = cmux_terminal_render_surface_right_import(
            rawResult.surfacePort
        ) else {
            return .dropped(.surfaceImportFailed, release: nil)
        }
        let surface = TerminalRenderSurfaceHandle(surface: importedSurface)
        guard surfaceDescriptorMatches(surface, metadata: metadata) else {
            return .dropped(
                .surfaceDescriptorMismatch,
                release: TerminalRenderFrameRelease(
                    metadata: metadata,
                    surfaceID: surface.identifier
                )
            )
        }
        if let rejection {
            return .dropped(
                .stale(rejection),
                release: TerminalRenderFrameRelease(
                    metadata: metadata,
                    surfaceID: surface.identifier
                )
            )
        }

        acceptance = tentativeAcceptance
        let authenticatedWorker = try TerminalRenderWorkerIdentity(
            processID: rawResult.senderProcessID,
            effectiveUserID: rawResult.senderEffectiveUserID
        )
        return .frame(TerminalRenderFrame(
            metadata: metadata,
            surface: surface,
            workerIdentity: authenticatedWorker
        ))
    }

    /// Drains frames after the worker acknowledged that this presentation can
    /// no longer publish. Drained surfaces never reach Metal, so their exact
    /// leases can be returned immediately.
    ///
    /// The endpoint capability, metadata fence, and imported IOSurface
    /// descriptor remain mandatory. When readiness has not delivered the
    /// worker PID/eUID yet, only that peer binding is bypassed for this closed
    /// publication epoch. Normal ``receive(timeoutMilliseconds:)`` calls stay
    /// audit-token-bound and continue to reject an unauthorized receiver.
    public func drainQuiescedFrames() async throws -> [TerminalRenderFrameRelease] {
        var releases: [TerminalRenderFrameRelease] = []
        while true {
            switch try await receive(
                timeoutMilliseconds: 0,
                expectedWorker: expectedWorker,
                allowQuiescedPeer: true
            ) {
            case .frame(let frame):
                releases.append(TerminalRenderFrameRelease(
                    metadata: frame.metadata,
                    surfaceID: frame.surface.identifier
                ))
            case .dropped(_, let release):
                if let release {
                    releases.append(release)
                }
            case .timedOut:
                return releases
            }
        }
    }

    /// Destroys the receive right, waking a pending receive and rejecting future calls.
    public func stop() {
        guard !stopped else { return }
        stopped = true
        receiveSource.cancel()
        resumeReadinessWaiter(with: .stopped)
        if receivePort != UInt32(MACH_PORT_NULL) {
            cmux_terminal_render_receiver_destroy(receivePort)
            receivePort = UInt32(MACH_PORT_NULL)
        }
    }

    private static func releaseSurfaceRight(_ surfacePort: UInt32) {
        if surfacePort != UInt32(MACH_PORT_NULL) {
            cmux_terminal_render_surface_right_release(surfacePort)
        }
    }

    private func waitForReadiness(
        until deadline: ContinuousClock.Instant,
        clock: ContinuousClock
    ) async -> TerminalRenderReceiveWake {
        if stopped {
            return .stopped
        }
        if readyPending {
            readyPending = false
            return .ready
        }

        readinessToken &+= 1
        let token = readinessToken
        let receiver = self
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if stopped {
                    continuation.resume(returning: .stopped)
                    return
                }
                if readyPending {
                    readyPending = false
                    continuation.resume(returning: .ready)
                    return
                }
                readinessWaiter = continuation
                readinessTimeoutTask = Task { [weak self] in
                    do {
                        // A cancellable receive deadline is intended behavior, not polling.
                        try await clock.sleep(until: deadline)
                        await self?.expireReadinessWaiter(token: token)
                    } catch {
                        return
                    }
                }
            }
        } onCancel: {
            Task {
                await receiver.cancelReadinessWaiter(token: token)
            }
        }
    }

    private func signalReadiness() {
        guard !stopped else { return }
        if readinessWaiter == nil {
            readyPending = true
        } else {
            resumeReadinessWaiter(with: .ready)
        }
    }

    private func expireReadinessWaiter(token: UInt64) {
        guard token == readinessToken else { return }
        resumeReadinessWaiter(with: .timedOut)
    }

    private func cancelReadinessWaiter(token: UInt64) {
        guard token == readinessToken else { return }
        resumeReadinessWaiter(with: .cancelled)
    }

    private func resumeReadinessWaiter(with wake: TerminalRenderReceiveWake) {
        readinessTimeoutTask?.cancel()
        readinessTimeoutTask = nil
        let waiter = readinessWaiter
        readinessWaiter = nil
        waiter?.resume(returning: wake)
    }

    private func surfaceDescriptorMatches(
        _ surface: TerminalRenderSurfaceHandle,
        metadata: TerminalRenderFrameMetadata
    ) -> Bool {
        let expectedBytesPerElement = Int(metadata.pixelFormat.bytesPerPixel)
        let minimumBytesPerRow = Int(metadata.width) * expectedBytesPerElement
        let maximumBytesPerRow = minimumBytesPerRow + 4_096
        guard surface.width == Int(metadata.width),
              surface.height == Int(metadata.height),
              surface.pixelFormat == metadata.pixelFormat.rawValue,
              surface.planeCount == 0,
              surface.bytesPerElement == expectedBytesPerElement,
              surface.bytesPerRow >= minimumBytesPerRow,
              surface.bytesPerRow <= maximumBytesPerRow else {
            return false
        }
        let minimumAllocation = surface.bytesPerRow * Int(metadata.height)
        return surface.allocationSize >= minimumAllocation
            && surface.allocationSize <= minimumAllocation + 4_096
    }
}
