import CoreImage
import CoreVideo
import CmuxSimulator
import Darwin
import Foundation
import IOSurface
import libkern

struct SimulatorCameraInjectorAttachment: Equatable, Sendable {
    let processIdentifier: Int32?
    let isAttached: Bool
}

struct SimulatorCameraAttachmentSlotSnapshot: Equatable, Sendable {
    let processIdentifier: UInt32
    let heartbeatNanoseconds: UInt64
}

/// Lock-protected IOSurface ring matching serve-sim's Apache-2 SimCam wire
/// format. The injected app resolves surfaces by global ID while the pixels
/// remain owned by this worker.
final class SimulatorCameraSurfaceRing: @unchecked Sendable {
    static let width = 1280
    static let height = 720
    static let surfaceCount = 4

    let sharedMemoryName: String

    private static let attachmentSlotCount = 16
    private static let attachmentSlotByteCount = 16
    private static let attachmentTableByteCount = attachmentSlotCount * attachmentSlotByteCount
    private static let headerByteCount = 64
    private static let surfaceTableOffset = headerByteCount + attachmentTableByteCount
    private static let controlByteCount = surfaceTableOffset + 24
    private static let magic: UInt32 = 0x5343_4D31

    private let lock = NSLock()
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private let descriptor: Int32
    private let mapping: UnsafeMutableRawPointer
    private let surfaces: [IOSurface]

    init(deviceIdentifier: String) throws {
        sharedMemoryName = Self.makeSharedMemoryName(
            deviceIdentifier: deviceIdentifier,
            processIdentifier: getpid()
        )
        shm_unlink(sharedMemoryName)
        let descriptor = try Self.openSharedMemory(named: sharedMemoryName)
        guard descriptor >= 0 else {
            let detail = Self.errnoDescription(operation: "shm_open")
            throw SimulatorWorkerFailure.privateAPIUnavailable(
                "Could not create the synthetic-camera shared-memory control region: \(detail)"
            )
        }
        guard ftruncate(descriptor, off_t(Self.controlByteCount)) == 0 else {
            let detail = Self.errnoDescription(operation: "ftruncate")
            close(descriptor)
            shm_unlink(sharedMemoryName)
            throw SimulatorWorkerFailure.privateAPIUnavailable(
                "Could not size the synthetic-camera shared-memory control region: \(detail)"
            )
        }
        guard let mapping = mmap(
            nil,
            Self.controlByteCount,
            PROT_READ | PROT_WRITE,
            MAP_SHARED,
            descriptor,
            0
        ), mapping != MAP_FAILED else {
            let detail = Self.errnoDescription(operation: "mmap")
            close(descriptor)
            shm_unlink(sharedMemoryName)
            throw SimulatorWorkerFailure.privateAPIUnavailable(
                "Could not map the synthetic-camera shared-memory control region: \(detail)"
            )
        }

        var surfaces: [IOSurface] = []
        let properties: [String: Any] = [
            kIOSurfaceWidth as String: Self.width,
            kIOSurfaceHeight as String: Self.height,
            kIOSurfaceBytesPerElement as String: 4,
            kIOSurfacePixelFormat as String: kCVPixelFormatType_32BGRA,
            "IOSurfaceIsGlobal": true,
        ]
        for _ in 0..<Self.surfaceCount {
            guard let surface = IOSurfaceCreate(properties as CFDictionary) else {
                munmap(mapping, Self.controlByteCount)
                close(descriptor)
                shm_unlink(sharedMemoryName)
                throw SimulatorWorkerFailure.privateAPIUnavailable(
                    "Could not allocate a global IOSurface for synthetic camera frames."
                )
            }
            surfaces.append(surface)
        }

        self.descriptor = descriptor
        self.mapping = mapping
        self.surfaces = surfaces
        initializeControlRegion()
    }

    deinit {
        munmap(mapping, Self.controlByteCount)
        close(descriptor)
        shm_unlink(sharedMemoryName)
    }

    func setMirrored(_ mirrored: Bool?) {
        lock.withLock {
            let value: UInt8 = switch mirrored {
            case .some(true): 1
            case .some(false): 2
            case .none: 0
            }
            mapping.storeBytes(of: value, toByteOffset: 48, as: UInt8.self)
        }
    }

    func injectorAttachments(
        maximumHeartbeatAgeNanoseconds: UInt64 = 2_000_000_000
    ) -> [SimulatorCameraInjectorAttachment] {
        lock.withLock {
            let now = Self.monotonicNanoseconds()
            return (0..<Self.attachmentSlotCount).compactMap { index in
                let offset = Self.headerByteCount + index * Self.attachmentSlotByteCount
                let processPointer = mapping.advanced(by: offset)
                    .assumingMemoryBound(to: Int32.self)
                let rawProcessIdentifier = UInt32(
                    bitPattern: OSAtomicAdd32Barrier(0, processPointer)
                )
                guard rawProcessIdentifier > 0 else { return nil }
                let heartbeatPointer = mapping.advanced(by: offset + 8)
                    .assumingMemoryBound(to: Int64.self)
                let heartbeat = UInt64(
                    bitPattern: OSAtomicAdd64Barrier(0, heartbeatPointer)
                )
                return SimulatorCameraInjectorAttachment(
                    processIdentifier: Int32(bitPattern: rawProcessIdentifier),
                    isAttached: Self.isInjectorAttachmentFresh(
                        attached: true,
                        processIdentifier: rawProcessIdentifier,
                        heartbeatNanoseconds: heartbeat,
                        nowNanoseconds: now,
                        maximumAgeNanoseconds: maximumHeartbeatAgeNanoseconds
                    )
                )
            }
        }
    }

    func publish(_ image: CIImage, fillsFrame: Bool) {
        lock.withLock {
            let table = mapping + Self.surfaceTableOffset
            let currentIndex = Int(table.load(fromByteOffset: 4, as: UInt32.self))
            let nextIndex = (currentIndex + 1) % surfaces.count
            let surface = surfaces[nextIndex]
            let destination = CGRect(x: 0, y: 0, width: Self.width, height: Self.height)
            let prepared = Self.prepare(image, destination: destination, fillsFrame: fillsFrame)
            context.render(prepared, to: surface, bounds: destination, colorSpace: colorSpace)

            table.storeBytes(of: UInt32(nextIndex), toByteOffset: 4, as: UInt32.self)
            mapping.storeBytes(of: Self.monotonicNanoseconds(), toByteOffset: 40, as: UInt64.self)
            let sequence = mapping.advanced(by: 32).assumingMemoryBound(to: Int64.self)
            _ = OSAtomicIncrement64Barrier(sequence)
        }
    }

    func publish(pixelBuffer: CVPixelBuffer, fillsFrame: Bool) {
        publish(CIImage(cvPixelBuffer: pixelBuffer), fillsFrame: fillsFrame)
    }

    private func initializeControlRegion() {
        memset(mapping, 0, Self.controlByteCount)
        mapping.storeBytes(of: Self.magic, toByteOffset: 0, as: UInt32.self)
        mapping.storeBytes(of: UInt32(3), toByteOffset: 4, as: UInt32.self)
        mapping.storeBytes(of: UInt32(Self.width), toByteOffset: 8, as: UInt32.self)
        mapping.storeBytes(of: UInt32(Self.height), toByteOffset: 12, as: UInt32.self)
        mapping.storeBytes(of: UInt32(0), toByteOffset: 16, as: UInt32.self)
        mapping.storeBytes(
            of: UInt32(IOSurfaceGetBytesPerRow(surfaces[0])),
            toByteOffset: 20,
            as: UInt32.self
        )
        mapping.storeBytes(
            of: UInt64(Self.width * Self.height * 4),
            toByteOffset: 24,
            as: UInt64.self
        )
        mapping.storeBytes(of: UInt8(0xFF), toByteOffset: 48, as: UInt8.self)

        let table = mapping + Self.surfaceTableOffset
        table.storeBytes(of: UInt32(Self.surfaceCount), toByteOffset: 0, as: UInt32.self)
        table.storeBytes(of: UInt32(0), toByteOffset: 4, as: UInt32.self)
        for (index, surface) in surfaces.enumerated() {
            table.storeBytes(
                of: IOSurfaceGetID(surface),
                toByteOffset: 8 + index * MemoryLayout<UInt32>.size,
                as: UInt32.self
            )
        }
    }

    private static func prepare(
        _ image: CIImage,
        destination: CGRect,
        fillsFrame: Bool
    ) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else {
            return CIImage(color: .black).cropped(to: destination)
        }
        let scale = imageScale(
            source: extent.size,
            destination: destination.size,
            fillsFrame: fillsFrame
        )
        let normalized = image.transformed(
            by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
        )
        let scaled = normalized.transformed(
            by: CGAffineTransform(scaleX: scale, y: scale)
        )
        let translated = scaled.transformed(
            by: CGAffineTransform(
                translationX: destination.midX - scaled.extent.midX,
                y: destination.midY - scaled.extent.midY
            )
        )
        let background = CIImage(color: .black).cropped(to: destination)
        return translated.composited(over: background).cropped(to: destination)
    }

    nonisolated static func imageScale(
        source: CGSize,
        destination: CGSize,
        fillsFrame: Bool
    ) -> CGFloat {
        guard source.width > 0, source.height > 0 else { return 1 }
        let horizontalScale = destination.width / source.width
        let verticalScale = destination.height / source.height
        return fillsFrame
            ? max(horizontalScale, verticalScale)
            : min(horizontalScale, verticalScale)
    }

    private static func monotonicNanoseconds() -> UInt64 {
        var time = timespec()
        clock_gettime(CLOCK_MONOTONIC_RAW, &time)
        return UInt64(time.tv_sec) * 1_000_000_000 + UInt64(time.tv_nsec)
    }

    nonisolated static func isInjectorAttachmentFresh(
        attached: Bool,
        processIdentifier: UInt32,
        heartbeatNanoseconds: UInt64,
        nowNanoseconds: UInt64,
        maximumAgeNanoseconds: UInt64
    ) -> Bool {
        guard attached, processIdentifier > 0, heartbeatNanoseconds > 0,
              nowNanoseconds >= heartbeatNanoseconds else { return false }
        return nowNanoseconds - heartbeatNanoseconds <= maximumAgeNanoseconds
    }

    nonisolated static func attachmentSlotIndex(
        slots: [SimulatorCameraAttachmentSlotSnapshot],
        processIdentifier: UInt32,
        nowNanoseconds: UInt64,
        maximumAgeNanoseconds: UInt64
    ) -> Int? {
        slots.firstIndex { slot in
            if slot.processIdentifier == 0 || slot.processIdentifier == processIdentifier {
                return true
            }
            guard slot.heartbeatNanoseconds > 0,
                  nowNanoseconds >= slot.heartbeatNanoseconds else { return false }
            return nowNanoseconds - slot.heartbeatNanoseconds > maximumAgeNanoseconds
        }
    }

    nonisolated static func makeSharedMemoryName(
        deviceIdentifier: String,
        processIdentifier: Int32
    ) -> String {
        SimulatorCameraSharedMemory(
            deviceIdentifier: deviceIdentifier,
            processIdentifier: processIdentifier
        ).name
    }

    private static func errnoDescription(operation: String) -> String {
        let code = errno
        return "\(operation) errno \(code) (\(String(cString: strerror(code))))"
    }

    /// Swift cannot import variadic `shm_open`; resolve its fixed ABI from
    /// libc so the worker can create the POSIX name consumed by the injector.
    private static func openSharedMemory(named name: String) throws -> Int32 {
        typealias Function = @convention(c) (
            UnsafePointer<CChar>,
            Int32,
            mode_t
        ) -> Int32
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "shm_open") else {
            throw SimulatorWorkerFailure.privateAPIUnavailable(
                "The host C library does not expose POSIX shared memory."
            )
        }
        let function = unsafeBitCast(symbol, to: Function.self)
        return name.withCString {
            function($0, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        }
    }
}
