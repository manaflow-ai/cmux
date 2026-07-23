import CmuxSimulator
import Foundation
import IOSurface

/// Copies only the newest pending Simulator frame away from the main actor.
@MainActor
final class SimulatorFramebufferFramePublisher {
    let initialDescriptor: SimulatorFrameTransportDescriptor

    private let continuation: AsyncStream<SimulatorFramebufferFrame>.Continuation
    private let consumerTask: Task<Void, Never>
    private let clock = ContinuousClock()
    private let minimumFrameInterval: Duration
    private let interactiveFrameInterval: Duration
    private var lastEnqueuedInstant: ContinuousClock.Instant
    private var prioritizeNextEnqueue = false
    private var pendingFrame: SimulatorFramebufferFrame?
    private var pendingFrameDeadline: ContinuousClock.Instant?
    private var pacingTask: Task<Void, Never>?
    private var pacingTaskDeadline: ContinuousClock.Instant?
    private var lastEnqueuedWidth: Int
    private var lastEnqueuedHeight: Int
    private var lastEnqueuedGeometry: SimulatorSurfaceGeometry?

    init(
        initialSurface: IOSurface,
        initialGeometry: SimulatorSurfaceGeometry? = nil,
        minimumFrameInterval: Duration = .milliseconds(30),
        interactiveFrameInterval: Duration = .milliseconds(16),
        beforeFrameTransportChange: @escaping @Sendable () async -> Void = {},
        afterFrameTransportChange: @escaping @Sendable () async -> Void = {},
        onFrameTransportChange: @escaping @MainActor @Sendable (
            SimulatorFrameTransportDescriptor
        ) -> Void
    ) async throws {
        let initialFrame = SimulatorFramebufferFrame(
            surface: initialSurface,
            geometry: initialGeometry
        )
        lastEnqueuedWidth = initialFrame.width
        lastEnqueuedHeight = initialFrame.height
        lastEnqueuedGeometry = initialGeometry
        self.minimumFrameInterval = minimumFrameInterval
        self.interactiveFrameInterval = min(
            interactiveFrameInterval,
            minimumFrameInterval
        )
        lastEnqueuedInstant = clock.now
        let initialRing = try await Task.detached(priority: .userInitiated) {
            let ring = try SimulatorFramebufferSurfaceRing(
                width: initialFrame.width,
                height: initialFrame.height
            )
            try ring.publish(initialFrame.surface)
            return ring
        }.value
        initialDescriptor = initialRing.descriptor
        let source = AsyncStream.makeStream(
            of: SimulatorFramebufferFrame.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        continuation = source.continuation
        consumerTask = Task.detached(priority: .userInitiated) {
            var ring = initialRing
            var retiredSharedMemoryNames: Set<String> = []
            defer {
                for name in retiredSharedMemoryNames {
                    simulatorUnlinkFrameSharedMemory(named: name)
                }
            }
            for await frame in source.stream {
                guard !Task.isCancelled else { return }
                do {
                    let transportChanged = ring.descriptor.width != frame.width
                        || ring.descriptor.height != frame.height
                    if transportChanged {
                        let replacement = try SimulatorFramebufferSurfaceRing(
                            width: frame.width,
                            height: frame.height
                        )
                        retiredSharedMemoryNames.insert(ring.descriptor.sharedMemoryName)
                        ring.releaseResources(unlinkSharedMemory: false)
                        ring = replacement
                    }
                    try ring.publish(frame.surface)
                    if transportChanged, !Task.isCancelled {
                        await beforeFrameTransportChange()
                        await onFrameTransportChange(ring.descriptor)
                        await afterFrameTransportChange()
                    }
                } catch {
                    continue
                }
            }
        }
        lastEnqueuedInstant = clock.now
    }

    deinit {
        pacingTask?.cancel()
        continuation.finish()
        consumerTask.cancel()
    }

    func enqueue(_ surface: IOSurface, geometry: SimulatorSurfaceGeometry? = nil) {
        let frame = SimulatorFramebufferFrame(surface: surface, geometry: geometry)
        let geometryChanged = frame.width != lastEnqueuedWidth
            || frame.height != lastEnqueuedHeight
            || geometry != lastEnqueuedGeometry
        let now = clock.now
        let frameInterval = prioritizeNextEnqueue
            ? interactiveFrameInterval
            : minimumFrameInterval
        prioritizeNextEnqueue = false
        let deadline = lastEnqueuedInstant.advanced(by: frameInterval)
        if geometryChanged || now >= deadline {
            pacingTask?.cancel()
            pacingTask = nil
            pacingTaskDeadline = nil
            pendingFrame = nil
            pendingFrameDeadline = nil
            enqueueImmediately(frame, at: now)
            return
        }

        pendingFrame = frame
        pendingFrameDeadline = pendingFrameDeadline.map { min($0, deadline) } ?? deadline
        schedulePacingTask()
    }

    /// Lets the next real Simulator framebuffer callback use the interactive
    /// publication interval without forcing a copy of pixels that predate input.
    func prioritizeNextFrame() {
        prioritizeNextEnqueue = true
    }

    private func schedulePacingTask() {
        guard let deadline = pendingFrameDeadline else { return }
        if let pacingTaskDeadline, pacingTaskDeadline <= deadline { return }
        pacingTask?.cancel()
        pacingTaskDeadline = deadline
        pacingTask = Task { @MainActor [weak self, clock] in
            do {
                try await clock.sleep(until: deadline, tolerance: .milliseconds(2))
            } catch {
                return
            }
            self?.flushPendingFrame()
        }
    }

    func cancel() {
        pacingTask?.cancel()
        pacingTask = nil
        pacingTaskDeadline = nil
        pendingFrame = nil
        pendingFrameDeadline = nil
        prioritizeNextEnqueue = false
        continuation.finish()
        consumerTask.cancel()
    }

    private func flushPendingFrame() {
        pacingTask = nil
        pacingTaskDeadline = nil
        guard let frame = pendingFrame else { return }
        pendingFrame = nil
        pendingFrameDeadline = nil
        enqueueImmediately(frame, at: clock.now)
    }

    private func enqueueImmediately(
        _ frame: SimulatorFramebufferFrame,
        at instant: ContinuousClock.Instant
    ) {
        lastEnqueuedWidth = frame.width
        lastEnqueuedHeight = frame.height
        lastEnqueuedGeometry = frame.geometry
        lastEnqueuedInstant = instant
        continuation.yield(frame)
    }
}
