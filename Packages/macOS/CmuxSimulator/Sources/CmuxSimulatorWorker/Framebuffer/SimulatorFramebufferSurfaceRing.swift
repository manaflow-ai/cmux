import CmuxSimulator
import CoreImage
import CoreVideo
import Darwin
import Foundation
import IOSurface
import libkern

/// Worker-owned producer ring whose surfaces are retained and rendered by cmux.
///
/// The worker copies private Simulator framebuffer surfaces into global
/// IOSurfaces. The host resolves and retains those surfaces, so worker death
/// cannot leave Core Animation waiting on a worker-owned render context.
// SAFETY: ownership moves to one detached frame-publisher task after initial
// creation. No other executor accesses the ring or its CIContext concurrently.
final class SimulatorFramebufferSurfaceRing: @unchecked Sendable {
    private let controlByteCount = 32
    private let magic: UInt32 = 0x434D_5846
    private let version: UInt32 = 1
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private let descriptorHandle: Int32
    private let mapping: UnsafeMutableRawPointer
    private let surfaces: [IOSurface]

    let descriptor: SimulatorFrameTransportDescriptor

    init(width: Int, height: Int, surfaceCount: Int = 3) throws {
        guard (1...16_384).contains(width),
            (1...16_384).contains(height),
            (2...4).contains(surfaceCount)
        else {
            throw SimulatorWorkerFailure.framebufferUnavailable(
                "The Simulator framebuffer dimensions are outside the supported transport bounds."
            )
        }

        let name = simulatorFramebufferSharedMemoryName()
        shm_unlink(name)
        let handle = try simulatorOpenSharedMemory(
            named: name,
            flags: O_CREAT | O_EXCL | O_RDWR
        )
        guard handle >= 0 else {
            throw SimulatorWorkerFailure.framebufferUnavailable(
                "Could not create the Simulator framebuffer control region: \(simulatorFramebufferErrnoDescription())."
            )
        }
        _ = fcntl(handle, F_SETFD, FD_CLOEXEC)
        guard ftruncate(handle, off_t(controlByteCount)) == 0 else {
            let detail = simulatorFramebufferErrnoDescription()
            close(handle)
            shm_unlink(name)
            throw SimulatorWorkerFailure.framebufferUnavailable(
                "Could not size the Simulator framebuffer control region: \(detail)."
            )
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
            let detail = simulatorFramebufferErrnoDescription()
            close(handle)
            shm_unlink(name)
            throw SimulatorWorkerFailure.framebufferUnavailable(
                "Could not map the Simulator framebuffer control region: \(detail)."
            )
        }

        var surfaces: [IOSurface] = []
        let properties: [String: Any] = [
            kIOSurfaceWidth as String: width,
            kIOSurfaceHeight as String: height,
            kIOSurfaceBytesPerElement as String: 4,
            kIOSurfacePixelFormat as String: kCVPixelFormatType_32BGRA,
            "IOSurfaceIsGlobal": true,
        ]
        for _ in 0..<surfaceCount {
            guard let surface = IOSurfaceCreate(properties as CFDictionary),
                IOSurfaceGetID(surface) != 0
            else {
                munmap(mapping, controlByteCount)
                close(handle)
                shm_unlink(name)
                throw SimulatorWorkerFailure.framebufferUnavailable(
                    "Could not allocate a global IOSurface for Simulator frames."
                )
            }
            surfaces.append(surface)
        }

        descriptorHandle = handle
        self.mapping = mapping
        self.surfaces = surfaces
        descriptor = SimulatorFrameTransportDescriptor(
            sharedMemoryName: name,
            surfaceIdentifiers: surfaces.map(IOSurfaceGetID),
            width: width,
            height: height
        )
        memset(mapping, 0, controlByteCount)
        mapping.storeBytes(of: magic, toByteOffset: 0, as: UInt32.self)
        mapping.storeBytes(of: version, toByteOffset: 4, as: UInt32.self)
        mapping.storeBytes(of: Int32(-1), toByteOffset: 8, as: Int32.self)
        mapping.storeBytes(of: Int64(0), toByteOffset: 16, as: Int64.self)
    }

    deinit {
        munmap(mapping, controlByteCount)
        close(descriptorHandle)
        shm_unlink(descriptor.sharedMemoryName)
    }

    func publish(_ source: IOSurface) throws {
        guard IOSurfaceGetWidth(source) == descriptor.width,
            IOSurfaceGetHeight(source) == descriptor.height
        else {
            throw SimulatorWorkerFailure.framebufferUnavailable(
                "The Simulator framebuffer changed dimensions before its transport was replaced."
            )
        }
        let currentPointer = mapping.advanced(by: 8).assumingMemoryBound(to: Int32.self)
        let currentIndex = OSAtomicAdd32Barrier(0, currentPointer)
        let nextIndex = currentIndex < 0 ? 0 : (currentIndex + 1) % Int32(surfaces.count)
        let bounds = CGRect(x: 0, y: 0, width: descriptor.width, height: descriptor.height)
        context.render(
            CIImage(ioSurface: source),
            to: surfaces[Int(nextIndex)],
            bounds: bounds,
            colorSpace: colorSpace
        )
        let sequence = mapping.advanced(by: 16).assumingMemoryBound(to: Int64.self)
        // Publish through an odd/even sequence lock. Readers only accept an
        // even sequence observed unchanged on both sides of the index load.
        _ = OSAtomicIncrement64Barrier(sequence)
        _ = OSAtomicCompareAndSwap32Barrier(currentIndex, nextIndex, currentPointer)
        _ = OSAtomicIncrement64Barrier(sequence)
    }
}

private func simulatorFramebufferSharedMemoryName() -> String {
    let token = UUID().uuidString
        .replacingOccurrences(of: "-", with: "")
        .lowercased()
        .prefix(12)
    return "/cmux-sim-frame-\(token)"
}

private func simulatorFramebufferErrnoDescription() -> String {
    String(cString: strerror(errno))
}
