import CmuxSimulatorSystem
import Darwin
import IOSurface
import Testing

@testable import CmuxSimulator
@testable import CmuxSimulatorWorker

@Suite("Simulator framebuffer pacing")
struct SimulatorFramebufferFramePacingTests {
    @Test("Rapid Simulator frames are coalesced before GPU readback")
    @MainActor
    func rapidFramesAreCoalesced() async throws {
        let surface = try #require(IOSurfaceCreate([
            kIOSurfaceWidth: 32,
            kIOSurfaceHeight: 32,
            kIOSurfaceBytesPerElement: 4,
            kIOSurfaceBytesPerRow: 128,
            kIOSurfaceAllocSize: 4_096,
            kIOSurfacePixelFormat: UInt32(0x4247_5241),
        ] as CFDictionary))
        let publisher = try await SimulatorFramebufferFramePublisher(
            initialSurface: surface,
            onFrameTransportChange: { _ in }
        )
        defer { publisher.cancel() }

        let clock = ContinuousClock()
        for _ in 0..<20 {
            publisher.enqueue(surface)
            try await clock.sleep(for: .milliseconds(2))
        }
        try await clock.sleep(for: .milliseconds(80))

        let sequence = try publishedSequence(in: publisher.initialDescriptor)
        #expect(sequence <= 5)
    }

    private func publishedSequence(
        in descriptor: SimulatorFrameTransportDescriptor
    ) throws -> UInt64 {
        let layout = try SimulatorFrameSharedMemoryLayout(descriptor: descriptor)
        let handle = try simulatorOpenSharedMemory(
            named: descriptor.sharedMemoryName,
            flags: O_RDONLY
        )
        try #require(handle >= 0)
        defer { close(handle) }
        let mapping = try #require(mmap(
            nil,
            layout.totalByteCount,
            PROT_READ,
            MAP_SHARED,
            handle,
            0
        ))
        try #require(mapping != MAP_FAILED)
        defer { munmap(mapping, layout.totalByteCount) }
        let word = Int64(bitPattern: cmux_simulator_atomic_load_u64_acquire(
            layout.publishedWordPointer(in: mapping)
        ))
        return try #require(layout.decodePublishedWord(word)?.sequence)
    }
}
