import CmuxSimulator
import Foundation
import IOSurface

/// Copies only the newest pending Simulator frame away from the main actor.
final class SimulatorFramebufferFramePublisher {
    let initialDescriptor: SimulatorFrameTransportDescriptor

    private let continuation: AsyncStream<SimulatorFramebufferFrame>.Continuation
    private let consumerTask: Task<Void, Never>

    init(
        initialSurface: IOSurface,
        initialGeometry: SimulatorSurfaceGeometry? = nil,
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
                        ring.releaseResources()
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
    }

    deinit {
        cancel()
    }

    func enqueue(_ surface: IOSurface, geometry: SimulatorSurfaceGeometry? = nil) {
        continuation.yield(SimulatorFramebufferFrame(surface: surface, geometry: geometry))
    }

    func cancel() {
        continuation.finish()
        consumerTask.cancel()
    }
}
