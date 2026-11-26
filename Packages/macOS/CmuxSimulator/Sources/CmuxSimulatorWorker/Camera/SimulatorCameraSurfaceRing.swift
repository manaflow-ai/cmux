import CoreImage
import CoreVideo
import CmuxSimulator
import Darwin
import Foundation
import libkern

/// Single-producer private shared-memory ring derived from serve-sim's
/// Apache-2 SimCam wire format. Camera pixels never enter the global IOSurface
/// namespace and the injected app receives only an unguessable region name.
// SAFETY: source transitions cancel and join playback tasks or drain the
// serial AVFoundation callback queue before the next producer starts. The
// injected process accesses shared fields through atomic operations, while
// host control operations touch disjoint bytes in the mapped frame region.
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
    private static let frameTableByteCount = 8
    private static let controlByteCount = surfaceTableOffset + frameTableByteCount
    private static let bytesPerRow = width * 4
    private static let frameByteCount = bytesPerRow * height
    private static let totalByteCount = controlByteCount + frameByteCount * surfaceCount
    private static let magic: UInt32 = 0x5343_4D31

    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private let descriptor: Int32
    private let mapping: UnsafeMutableRawPointer

    init(
        deviceIdentifier: String,
        sharedMemoryToken: String? = ProcessInfo.processInfo.environment[
            SimulatorCameraSharedMemory.tokenEnvironmentKey
        ]
    ) throws {
        guard let sharedMemoryToken, !sharedMemoryToken.isEmpty else {
            throw SimulatorWorkerFailure.privateAPIUnavailable(
                "The synthetic-camera private transport token is unavailable."
            )
        }
        sharedMemoryName = simulatorCameraSharedMemoryName(
            deviceIdentifier: deviceIdentifier,
            processIdentifier: getpid(),
            token: sharedMemoryToken
        )
        shm_unlink(sharedMemoryName)
        let descriptor = try simulatorOpenSharedMemory(
            named: sharedMemoryName,
            flags: O_CREAT | O_RDWR
        )
        guard descriptor >= 0 else {
            let detail = simulatorCameraErrnoDescription(operation: "shm_open")
            throw SimulatorWorkerFailure.privateAPIUnavailable(
                "Could not create the synthetic-camera shared-memory control region: \(detail)"
            )
        }
        guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) != -1 else {
            let detail = simulatorCameraErrnoDescription(operation: "fcntl")
            close(descriptor)
            shm_unlink(sharedMemoryName)
            throw SimulatorWorkerFailure.privateAPIUnavailable(
                "Could not isolate the synthetic-camera descriptor: \(detail)"
            )
        }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_uid == geteuid(),
              metadata.st_mode & (S_IRWXU | S_IRWXG | S_IRWXO)
                == (S_IRUSR | S_IWUSR) else {
            let detail = simulatorCameraErrnoDescription(operation: "fstat")
            close(descriptor)
            shm_unlink(sharedMemoryName)
            throw SimulatorWorkerFailure.privateAPIUnavailable(
                "Synthetic-camera shared-memory permissions are unsafe: \(detail)"
            )
        }
        guard ftruncate(descriptor, off_t(Self.totalByteCount)) == 0 else {
            let detail = simulatorCameraErrnoDescription(operation: "ftruncate")
            close(descriptor)
            shm_unlink(sharedMemoryName)
            throw SimulatorWorkerFailure.privateAPIUnavailable(
                "Could not size the synthetic-camera shared-memory control region: \(detail)"
            )
        }
        guard let mapping = mmap(
            nil,
            Self.totalByteCount,
            PROT_READ | PROT_WRITE,
            MAP_SHARED,
            descriptor,
            0
        ), mapping != MAP_FAILED else {
            let detail = simulatorCameraErrnoDescription(operation: "mmap")
            close(descriptor)
            shm_unlink(sharedMemoryName)
            throw SimulatorWorkerFailure.privateAPIUnavailable(
                "Could not map the synthetic-camera shared-memory control region: \(detail)"
            )
        }

        self.descriptor = descriptor
        self.mapping = mapping
        initializeControlRegion()
    }

    deinit {
        munmap(mapping, Self.totalByteCount)
        close(descriptor)
        shm_unlink(sharedMemoryName)
    }

    func setMirrored(_ mirrored: Bool?) {
        let value: UInt8 = switch mirrored {
        case .some(true): 1
        case .some(false): 2
        case .none: 0
        }
        mapping.storeBytes(of: value, toByteOffset: 48, as: UInt8.self)
    }

    func injectorAttachments(
        maximumHeartbeatAgeNanoseconds: UInt64 = 2_000_000_000
    ) -> [SimulatorCameraInjectorAttachment] {
        let now = simulatorCameraMonotonicNanoseconds()
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
                isAttached: simulatorCameraAttachmentIsFresh(
                    attached: true,
                    processIdentifier: rawProcessIdentifier,
                    heartbeatNanoseconds: heartbeat,
                    nowNanoseconds: now,
                    maximumAgeNanoseconds: maximumHeartbeatAgeNanoseconds
                )
            )
        }
    }

    func publish(_ image: CIImage, fillsFrame: Bool) {
        let table = mapping + Self.surfaceTableOffset
        let currentIndex = Int(table.load(fromByteOffset: 4, as: UInt32.self))
        let nextIndex = (currentIndex + 1) % Self.surfaceCount
        let destinationBaseAddress = mapping.advanced(
            by: Self.controlByteCount + nextIndex * Self.frameByteCount
        )
        let destination = CGRect(x: 0, y: 0, width: Self.width, height: Self.height)
        let prepared = prepareSimulatorCameraImage(
            image,
            destination: destination,
            fillsFrame: fillsFrame
        )
        context.render(
            prepared,
            toBitmap: destinationBaseAddress,
            rowBytes: Self.bytesPerRow,
            bounds: destination,
            format: .BGRA8,
            colorSpace: colorSpace
        )

        table.storeBytes(of: UInt32(nextIndex), toByteOffset: 4, as: UInt32.self)
        mapping.storeBytes(
            of: simulatorCameraMonotonicNanoseconds(),
            toByteOffset: 40,
            as: UInt64.self
        )
        let sequence = mapping.advanced(by: 32).assumingMemoryBound(to: Int64.self)
        _ = OSAtomicIncrement64Barrier(sequence)
    }

    func publish(pixelBuffer: CVPixelBuffer, fillsFrame: Bool) {
        publish(CIImage(cvPixelBuffer: pixelBuffer), fillsFrame: fillsFrame)
    }

    private func initializeControlRegion() {
        memset(mapping, 0, Self.totalByteCount)
        mapping.storeBytes(of: Self.magic, toByteOffset: 0, as: UInt32.self)
        mapping.storeBytes(of: UInt32(4), toByteOffset: 4, as: UInt32.self)
        mapping.storeBytes(of: UInt32(Self.width), toByteOffset: 8, as: UInt32.self)
        mapping.storeBytes(of: UInt32(Self.height), toByteOffset: 12, as: UInt32.self)
        mapping.storeBytes(of: UInt32(0), toByteOffset: 16, as: UInt32.self)
        mapping.storeBytes(
            of: UInt32(Self.bytesPerRow),
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
    }

}

func simulatorCameraImageScale(
    source: CGSize,
    destination: CGSize,
    fillsFrame: Bool
) -> CGFloat {
    guard source.width > 0, source.height > 0 else { return 1 }
    let horizontalScale = destination.width / source.width
    let verticalScale = destination.height / source.height
    return fillsFrame ? max(horizontalScale, verticalScale) : min(horizontalScale, verticalScale)
}

func simulatorCameraAttachmentIsFresh(
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

func simulatorCameraAttachmentSlotIndex(
    slots: [SimulatorCameraAttachmentSlotSnapshot],
    processIdentifier: UInt32,
    nowNanoseconds: UInt64,
    maximumAgeNanoseconds: UInt64
) -> Int? {
    slots.firstIndex { slot in
        if slot.processIdentifier == 0 || slot.processIdentifier == processIdentifier { return true }
        guard slot.heartbeatNanoseconds > 0,
              nowNanoseconds >= slot.heartbeatNanoseconds else { return false }
        return nowNanoseconds - slot.heartbeatNanoseconds > maximumAgeNanoseconds
    }
}

func simulatorCameraSharedMemoryName(
    deviceIdentifier: String,
    processIdentifier: Int32,
    token: String
) -> String {
    SimulatorCameraSharedMemory(
        deviceIdentifier: deviceIdentifier,
        processIdentifier: processIdentifier,
        token: token
    ).name
}

private func prepareSimulatorCameraImage(
    _ image: CIImage,
    destination: CGRect,
    fillsFrame: Bool
) -> CIImage {
    let extent = image.extent
    guard extent.width > 0, extent.height > 0 else {
        return CIImage(color: .black).cropped(to: destination)
    }
    let scale = simulatorCameraImageScale(
        source: extent.size,
        destination: destination.size,
        fillsFrame: fillsFrame
    )
    let normalized = image.transformed(
        by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
    )
    let scaled = normalized.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    let translated = scaled.transformed(
        by: CGAffineTransform(
            translationX: destination.midX - scaled.extent.midX,
            y: destination.midY - scaled.extent.midY
        )
    )
    let background = CIImage(color: .black).cropped(to: destination)
    return translated.composited(over: background).cropped(to: destination)
}

private func simulatorCameraMonotonicNanoseconds() -> UInt64 {
    var time = timespec()
    clock_gettime(CLOCK_MONOTONIC_RAW, &time)
    return UInt64(time.tv_sec) * 1_000_000_000 + UInt64(time.tv_nsec)
}

private func simulatorCameraErrnoDescription(operation: String) -> String {
    let code = errno
    return "\(operation) errno \(code) (\(String(cString: strerror(code))))"
}
