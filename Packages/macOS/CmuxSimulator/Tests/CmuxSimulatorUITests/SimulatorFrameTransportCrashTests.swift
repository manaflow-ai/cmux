import CoreVideo
import CmuxSimulator
import CmuxSimulatorSystem
import Darwin
import IOSurface
import Testing

@testable import CmuxSimulatorUI
@testable import CmuxSimulatorWorker

@Suite("Simulator frame transport crash containment")
struct SimulatorFrameTransportCrashTests {
    @Test("The host resolves unaligned phone-sized frame surfaces")
    func hostResolvesPhoneSizedSurfaces() async throws {
        let producer = try SimulatorFramebufferSurfaceRing(width: 390, height: 844)

        let source = try SimulatorFrameSurfaceSource(descriptor: producer.descriptor)

        #expect(await source.copyLatestFrame(after: nil) == nil)
    }

    @Test("The host retains the last frame after its worker-owned producer disappears")
    func hostRetainsFrameAfterProducerRelease() async throws {
        var producer: SimulatorFramebufferSurfaceRing? = try SimulatorFramebufferSurfaceRing(
            width: 2,
            height: 2
        )
        let source = try SimulatorFrameSurfaceSource(
            descriptor: try #require(producer).descriptor
        )
        let input = try makeInputSurface(pixel: 0xFF_33_22_11)

        try #require(producer).publish(input)
        #expect(readFirstPixel(try #require(await source.copyLatestFrame(after: nil))) == 0xFF_33_22_11)

        producer = nil

        #expect(readFirstPixel(try #require(await source.copyLatestFrame(after: nil))) == 0xFF_33_22_11)
    }

    @Test("Frame sequences advance and unchanged frames are not recopied")
    func frameSequencesAdvance() async throws {
        let producer = try SimulatorFramebufferSurfaceRing(width: 2, height: 2)
        let source = try SimulatorFrameSurfaceSource(descriptor: producer.descriptor)
        var previousSequence: UInt64?

        for expectedSequence in UInt64(1)...4 {
            let pixel = UInt32(0xFF_00_00_00) | UInt32(expectedSequence)
            try producer.publish(makeInputSurface(pixel: pixel))
            var snapshot: SimulatorFrameSnapshot? = await source.copyLatestFrame(
                after: previousSequence
            )
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(2))
            while snapshot == nil, clock.now < deadline {
                try await clock.sleep(for: .milliseconds(1))
                snapshot = await source.copyLatestFrame(after: previousSequence)
            }
            do {
                let frame = try #require(snapshot)
                #expect(frame.sequence == expectedSequence)
                #expect(readFirstPixel(frame) == pixel)
                previousSequence = frame.sequence
            }
            snapshot = nil
        }

        #expect(await source.copyLatestFrame(after: previousSequence) == nil)
    }

    @Test("Worker publication scales a native surface into the bounded host ring")
    func framePublicationDownscales() async throws {
        let producer = try SimulatorFramebufferSurfaceRing(width: 1, height: 1)
        let source = try SimulatorFrameSurfaceSource(descriptor: producer.descriptor)

        try producer.publish(makeInputSurface(pixel: 0xFF_44_33_22))

        let snapshot = try #require(await source.copyLatestFrame(after: nil))
        #expect(snapshot.width == 1)
        #expect(snapshot.height == 1)
        #expect(readFirstPixel(snapshot) == 0xFF_44_33_22)
    }

    @Test("Concurrent slot reuse never publishes torn pixels")
    func concurrentSlotReuseRejectsTornFrames() async throws {
        let producer = try SimulatorFramebufferSurfaceRing(width: 512, height: 512)
        let source = try SimulatorFrameSurfaceSource(descriptor: producer.descriptor)
        let finalSequence: UInt64 = 64
        let writer = Task.detached(priority: .userInitiated) {
            for sequence in UInt64(1)...finalSequence {
                try producer.publish(makeConcurrentInputSurface(
                    pixel: concurrentFramePixel(sequence)
                ))
                if sequence.isMultiple(of: 4) { await Task.yield() }
            }
        }
        var lastSequence: UInt64?
        var verifiedFrameCount = 0
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))

        while lastSequence != finalSequence, clock.now < deadline {
            if let snapshot = await source.copyLatestFrame(after: lastSequence) {
                #expect(snapshotHasUniformPixels(
                    snapshot,
                    expected: concurrentFramePixel(snapshot.sequence)
                ))
                lastSequence = snapshot.sequence
                verifiedFrameCount += 1
            }
            await Task.yield()
        }
        try await writer.value
        if lastSequence != finalSequence,
           let snapshot = await source.copyLatestFrame(after: lastSequence) {
            #expect(snapshotHasUniformPixels(
                snapshot,
                expected: concurrentFramePixel(snapshot.sequence)
            ))
            lastSequence = snapshot.sequence
            verifiedFrameCount += 1
        }

        #expect(lastSequence == finalSequence)
        #expect(verifiedFrameCount > 0)
    }

    @Test("Framebuffer shared memory is private and exactly sized")
    func frameRingPermissionsAndSize() throws {
        let producer = try SimulatorFramebufferSurfaceRing(width: 390, height: 844)
        let descriptor = producer.descriptor
        let handle = try simulatorOpenSharedMemory(
            named: descriptor.sharedMemoryName,
            flags: O_RDONLY
        )
        defer { close(handle) }
        var metadata = stat()
        #expect(handle >= 0)
        #expect(fstat(handle, &metadata) == 0)
        #expect(metadata.st_uid == geteuid())
        #expect(
            metadata.st_mode & (S_IRWXU | S_IRWXG | S_IRWXO)
                == (S_IRUSR | S_IWUSR)
        )
        #expect(metadata.st_size == off_t(descriptor.sharedMemoryByteCount))
        #expect(fcntl(handle, F_GETFL) & O_ACCMODE == O_RDONLY)
        withExtendedLifetime(producer) {}
    }

    @Test("Odd, invalid, and mid-copy frame publications are discarded")
    func unstableFramesAreDiscarded() async throws {
        let producer = try SimulatorFramebufferSurfaceRing(width: 2, height: 2)
        try producer.publish(makeInputSurface(pixel: 0xFF_11_22_33))
        let descriptor = producer.descriptor
        let layout = try SimulatorFrameSharedMemoryLayout(descriptor: descriptor)
        let handle = try simulatorOpenSharedMemory(
            named: descriptor.sharedMemoryName,
            flags: O_RDWR
        )
        let mapping = try #require(mmap(
            nil,
            layout.totalByteCount,
            PROT_READ | PROT_WRITE,
            MAP_SHARED,
            handle,
            0
        ))
        #expect(mapping != MAP_FAILED)
        defer {
            munmap(mapping, layout.totalByteCount)
            close(handle)
        }
        let publication = layout.publishedWordPointer(in: mapping)
        let stableWord = cmux_simulator_atomic_load_u64_acquire(publication)
        let decoded = try #require(layout.decodePublishedWord(Int64(bitPattern: stableWord)))
        let version = try #require(layout.slotVersionPointer(slot: decoded.slot, in: mapping))
        let stableVersion = cmux_simulator_atomic_load_u64_acquire(version)

        cmux_simulator_atomic_store_u64_release(version, stableVersion | 1)
        let source = try SimulatorFrameSurfaceSource(descriptor: descriptor)
        #expect(await source.copyLatestFrame(after: nil) == nil)
        cmux_simulator_atomic_store_u64_release(version, stableVersion)

        cmux_simulator_atomic_store_u64_release(
            publication,
            (decoded.sequence << 2) | 3
        )
        #expect(await source.copyLatestFrame(after: nil) == nil)
        cmux_simulator_atomic_store_u64_release(publication, stableWord)

        let mutatingSource = try SimulatorFrameSurfaceSource(
            descriptor: descriptor,
            byteCopier: MutatingSimulatorFrameByteCopier {
                cmux_simulator_atomic_store_u64_release(version, stableVersion | 1)
            }
        )
        #expect(await mutatingSource.copyLatestFrame(after: nil) == nil)
        cmux_simulator_atomic_store_u64_release(version, stableVersion)
        withExtendedLifetime(producer) {}
    }

    private func makeInputSurface(pixel: UInt32) throws -> IOSurface {
        let properties: [String: Any] = [
            kIOSurfaceWidth as String: 2,
            kIOSurfaceHeight as String: 2,
            kIOSurfaceBytesPerElement as String: 4,
            kIOSurfacePixelFormat as String: kCVPixelFormatType_32BGRA,
        ]
        let surface = try #require(IOSurfaceCreate(properties as CFDictionary))
        IOSurfaceLock(surface, [], nil)
        defer { IOSurfaceUnlock(surface, [], nil) }
        let baseAddress = IOSurfaceGetBaseAddress(surface)
        let bytesPerRow = IOSurfaceGetBytesPerRow(surface)
        for row in 0..<2 {
            let pixels = baseAddress.advanced(by: row * bytesPerRow)
                .assumingMemoryBound(to: UInt32.self)
            for column in 0..<2 {
                pixels[column] = pixel
            }
        }
        return surface
    }

    private func readFirstPixel(_ snapshot: SimulatorFrameSnapshot) -> UInt32 {
        snapshot.pixels.withUnsafeBytes {
            $0.load(as: UInt32.self)
        }
    }
}

private func concurrentFramePixel(_ sequence: UInt64) -> UInt32 {
    0xFF_00_00_00 | UInt32(truncatingIfNeeded: sequence)
}

private func makeConcurrentInputSurface(pixel: UInt32) throws -> IOSurface {
    let properties: [String: Any] = [
        kIOSurfaceWidth as String: 512,
        kIOSurfaceHeight as String: 512,
        kIOSurfaceBytesPerElement as String: 4,
        kIOSurfacePixelFormat as String: kCVPixelFormatType_32BGRA,
    ]
    let surface = try #require(IOSurfaceCreate(properties as CFDictionary))
    IOSurfaceLock(surface, [], nil)
    defer { IOSurfaceUnlock(surface, [], nil) }
    let pixels = IOSurfaceGetBaseAddress(surface).assumingMemoryBound(to: UInt32.self)
    for index in 0..<(512 * 512) { pixels[index] = pixel }
    return surface
}

private func snapshotHasUniformPixels(
    _ snapshot: SimulatorFrameSnapshot,
    expected: UInt32
) -> Bool {
    snapshot.pixels.withUnsafeBytes { bytes in
        stride(from: 0, to: bytes.count, by: MemoryLayout<UInt32>.stride).allSatisfy {
            bytes.loadUnaligned(fromByteOffset: $0, as: UInt32.self) == expected
        }
    }
}
