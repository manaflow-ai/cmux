import CmuxSimulator
import Darwin
import Foundation
import IOSurface
import libkern

/// Host-owned view of one worker-published framebuffer ring.
///
/// Resolving the global identifiers retains each IOSurface in cmux. The last
/// complete frame therefore remains a local Core Animation resource even when
/// the producer process exits without cleanup.
final class SimulatorFrameSurfaceSource: SimulatorFrameSurfaceReading {
    private let controlByteCount = 32
    private let descriptorHandle: Int32
    private let mapping: UnsafeMutableRawPointer
    private let surfaces: [IOSurface]

    init(descriptor: SimulatorFrameTransportDescriptor) throws {
        guard simulatorFrameSharedMemoryNameIsValid(descriptor.sharedMemoryName),
            (2...4).contains(descriptor.surfaceIdentifiers.count),
            Set(descriptor.surfaceIdentifiers).count == descriptor.surfaceIdentifiers.count,
            (1...16_384).contains(descriptor.width),
            (1...16_384).contains(descriptor.height),
            descriptor.surfaceIdentifiers.allSatisfy({ $0 != 0 })
        else {
            throw simulatorFrameTransportError("The worker supplied an invalid frame descriptor.")
        }
        let handle = try simulatorOpenSharedMemory(
            named: descriptor.sharedMemoryName,
            flags: O_RDWR
        )
        guard handle >= 0 else {
            throw simulatorFrameTransportError("The worker frame control region is unavailable.")
        }
        _ = fcntl(handle, F_SETFD, FD_CLOEXEC)
        var status = stat()
        guard fstat(handle, &status) == 0, status.st_size >= controlByteCount else {
            close(handle)
            throw simulatorFrameTransportError("The worker frame control region is truncated.")
        }
        guard
            let mapping = mmap(
                nil,
                controlByteCount,
                PROT_READ | PROT_WRITE,
                MAP_SHARED,
                handle,
                0
            ), mapping != MAP_FAILED
        else {
            close(handle)
            throw simulatorFrameTransportError("The worker frame control region could not be mapped.")
        }
        guard mapping.load(fromByteOffset: 0, as: UInt32.self) == 0x434D_5846,
            mapping.load(fromByteOffset: 4, as: UInt32.self) == 1
        else {
            munmap(mapping, controlByteCount)
            close(handle)
            throw simulatorFrameTransportError("The worker frame control protocol is unsupported.")
        }
        let surfaces = descriptor.surfaceIdentifiers.compactMap(IOSurfaceLookup)
        guard surfaces.count == descriptor.surfaceIdentifiers.count,
            surfaces.allSatisfy({
                IOSurfaceGetWidth($0) == descriptor.width
                    && IOSurfaceGetHeight($0) == descriptor.height
            })
        else {
            munmap(mapping, controlByteCount)
            close(handle)
            throw simulatorFrameTransportError("The worker frame surfaces could not be retained.")
        }
        descriptorHandle = handle
        self.mapping = mapping
        self.surfaces = surfaces
    }

    deinit {
        munmap(mapping, controlByteCount)
        close(descriptorHandle)
    }

    var latestSurface: IOSurface? {
        latestFrame?.surface
    }

    var latestFrame: (surface: IOSurface, sequence: UInt64)? {
        let sequencePointer = mapping.advanced(by: 16).assumingMemoryBound(to: Int64.self)
        let firstSequence = UInt64(bitPattern: OSAtomicAdd64Barrier(0, sequencePointer))
        guard firstSequence > 0, firstSequence.isMultiple(of: 2) else { return nil }
        let indexPointer = mapping.advanced(by: 8).assumingMemoryBound(to: Int32.self)
        let index = OSAtomicAdd32Barrier(0, indexPointer)
        let secondSequence = UInt64(bitPattern: OSAtomicAdd64Barrier(0, sequencePointer))
        guard firstSequence == secondSequence,
            index >= 0,
            Int(index) < surfaces.count
        else { return nil }
        return (surfaces[Int(index)], secondSequence)
    }
}

private func simulatorFrameTransportError(_ message: String) -> NSError {
    NSError(
        domain: "com.cmux.simulator.frame-transport",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: message]
    )
}
