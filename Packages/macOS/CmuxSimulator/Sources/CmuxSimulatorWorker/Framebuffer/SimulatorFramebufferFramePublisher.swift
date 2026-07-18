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
    private var nextFrameDeadline: ContinuousClock.Instant?
    private var pendingFrame: SimulatorFramebufferFrame?
    private var pacingTask: Task<Void, Never>?
    private var lastEnqueuedWidth: Int
    private var lastEnqueuedHeight: Int
    private var lastEnqueuedGeometry: SimulatorSurfaceGeometry?

    init(
        initialSurface: IOSurface,
        initialGeometry: SimulatorSurfaceGeometry? = nil,
        minimumFrameInterval: Duration = .milliseconds(30),
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
        nextFrameDeadline = clock.now.advanced(by: minimumFrameInterval)
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
        if geometryChanged || nextFrameDeadline.map({ now >= $0 }) ?? true {
            pacingTask?.cancel()
            pacingTask = nil
            pendingFrame = nil
            enqueueImmediately(frame, at: now)
            return
        }

        pendingFrame = frame
        guard pacingTask == nil, let deadline = nextFrameDeadline else { return }
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
        pendingFrame = nil
        continuation.finish()
        consumerTask.cancel()
    }

    private func flushPendingFrame() {
        pacingTask = nil
        guard let frame = pendingFrame else { return }
        pendingFrame = nil
        enqueueImmediately(frame, at: clock.now)
    }

    private func enqueueImmediately(
        _ frame: SimulatorFramebufferFrame,
        at instant: ContinuousClock.Instant
    ) {
        lastEnqueuedWidth = frame.width
        lastEnqueuedHeight = frame.height
        lastEnqueuedGeometry = frame.geometry
        nextFrameDeadline = instant.advanced(by: minimumFrameInterval)
        continuation.yield(frame)
    }
}
