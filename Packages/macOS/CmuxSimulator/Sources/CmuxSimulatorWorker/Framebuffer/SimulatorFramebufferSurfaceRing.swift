import CmuxSimulator
import CmuxSimulatorSystem
import CoreImage
import Darwin
import Foundation
import IOSurface
import notify

/// Worker-owned producer for a permission-restricted packed-BGRA triple ring.
///
/// Simulator IOSurface and GPU synchronization remain inside the isolated
/// worker. The host receives only read-only shared bytes with versioned slots.
// SAFETY: ownership moves to one detached frame-publisher task after initial
// creation. No other executor accesses the mapping or CIContext concurrently.
final class SimulatorFramebufferSurfaceRing: @unchecked Sendable {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private let descriptorHandle: Int32
    private let mapping: UnsafeMutableRawPointer
    private let layout: SimulatorFrameSharedMemoryLayout
    private var frameSequence: UInt64 = 0
    private var isClosed = false

    let descriptor: SimulatorFrameTransportDescriptor

    init(width: Int, height: Int) throws {
        let layout: SimulatorFrameSharedMemoryLayout
        do {
            layout = try SimulatorFrameSharedMemoryLayout(width: width, height: height)
        } catch {
            throw SimulatorWorkerFailure.framebufferUnavailable(error.localizedDescription)
        }
        guard cmux_simulator_atomic_u64_is_lock_free() else {
            throw SimulatorWorkerFailure.framebufferUnavailable(
                "Lock-free Simulator framebuffer publication is unavailable."
            )
        }

        let (name, handle) = try createSimulatorFramebufferSharedMemory()
        guard fcntl(handle, F_SETFD, FD_CLOEXEC) != -1 else {
            let detail = simulatorFramebufferErrnoDescription()
            close(handle)
            shm_unlink(name)
            throw SimulatorWorkerFailure.framebufferUnavailable(
                "Could not isolate the Simulator framebuffer descriptor: \(detail)."
            )
        }
        var metadata = stat()
        let metadataResult = fstat(handle, &metadata)
        guard metadataResult == 0,
              metadata.st_uid == geteuid(),
              metadata.st_mode & (S_IRWXU | S_IRWXG | S_IRWXO)
                == (S_IRUSR | S_IWUSR) else {
            let detail = simulatorFramebufferErrnoDescription()
            close(handle)
            shm_unlink(name)
            throw SimulatorWorkerFailure.framebufferUnavailable(
                "Simulator framebuffer ring permissions are unsafe: \(detail)."
            )
        }
        guard ftruncate(handle, off_t(layout.totalByteCount)) == 0 else {
            let detail = simulatorFramebufferErrnoDescription()
            close(handle)
            shm_unlink(name)
            throw SimulatorWorkerFailure.framebufferUnavailable(
                "Could not size the Simulator framebuffer ring: \(detail)."
            )
        }
        guard
            let mapping = mmap(
                nil,
                layout.totalByteCount,
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
                "Could not map the Simulator framebuffer ring: \(detail)."
            )
        }

        descriptorHandle = handle
        self.mapping = mapping
        self.layout = layout
        descriptor = SimulatorFrameTransportDescriptor(
            sharedMemoryName: name,
            width: width,
            height: height,
            bytesPerRow: layout.bytesPerRow,
            slotCount: layout.slotCount,
            sharedMemoryByteCount: layout.totalByteCount
        )
        layout.initializeHeader(at: mapping)
        cmux_simulator_atomic_store_u64_release(
            layout.publishedWordPointer(in: mapping),
            0
        )
        for slot in 0..<layout.slotCount {
            guard let versionPointer = layout.slotVersionPointer(slot: slot, in: mapping) else {
                continue
            }
            cmux_simulator_atomic_store_u64_release(versionPointer, 0)
        }
    }

    deinit {
        releaseResources()
    }

    func releaseResources(unlinkSharedMemory: Bool = true) {
        guard !isClosed else { return }
        isClosed = true
        munmap(mapping, layout.totalByteCount)
        close(descriptorHandle)
        if unlinkSharedMemory {
            shm_unlink(descriptor.sharedMemoryName)
        }
    }

    func publish(_ source: IOSurface) throws {
        guard !isClosed else {
            throw SimulatorWorkerFailure.framebufferUnavailable(
                "The Simulator framebuffer ring is closed."
            )
        }
        let sourceWidth = IOSurfaceGetWidth(source)
        let sourceHeight = IOSurfaceGetHeight(source)
        guard sourceWidth > 0, sourceHeight > 0 else {
            throw SimulatorWorkerFailure.framebufferUnavailable(
                "The Simulator framebuffer has invalid dimensions."
            )
        }
        let (nextSequence, sequenceOverflow) = frameSequence.addingReportingOverflow(1)
        let nextSlot = Int(frameSequence % UInt64(layout.slotCount))
        guard !sequenceOverflow,
              let completedVersion = layout.completedSlotVersion(frameSequence: nextSequence),
              let nextPublishedWord = layout.publishedWord(
                frameSequence: nextSequence,
                slot: nextSlot
              ),
              let versionPointer = layout.slotVersionPointer(slot: nextSlot, in: mapping),
              let slotBytes = layout.slotBytes(slot: nextSlot, in: mapping)
        else {
            throw SimulatorWorkerFailure.framebufferUnavailable(
                "The Simulator framebuffer sequence exceeded transport bounds."
            )
        }

        let writingVersion = completedVersion - 1
        _ = cmux_simulator_atomic_exchange_u64_acq_rel(
            versionPointer,
            UInt64(bitPattern: writingVersion)
        )

        let bounds = CGRect(x: 0, y: 0, width: layout.width, height: layout.height)
        let image = CIImage(ioSurface: source).transformed(by: CGAffineTransform(
            scaleX: Double(layout.width) / Double(sourceWidth),
            y: Double(layout.height) / Double(sourceHeight)
        ))
        context.render(
            image,
            toBitmap: UnsafeMutableRawPointer(mutating: slotBytes),
            rowBytes: layout.bytesPerRow,
            bounds: bounds,
            format: .BGRA8,
            colorSpace: colorSpace
        )

        cmux_simulator_atomic_store_u64_release(
            versionPointer,
            UInt64(bitPattern: completedVersion)
        )
        cmux_simulator_atomic_store_u64_release(
            layout.publishedWordPointer(in: mapping),
            UInt64(bitPattern: nextPublishedWord)
        )
        frameSequence = nextSequence
        if let notificationName = descriptor.framePublicationNotificationName,
           notify_post(notificationName) != NOTIFY_STATUS_OK {
            throw SimulatorWorkerFailure.framebufferUnavailable(
                "Could not signal Simulator framebuffer publication."
            )
        }
    }
}

private func createSimulatorFramebufferSharedMemory() throws -> (name: String, handle: Int32) {
    for _ in 0..<8 {
        let name = simulatorFramebufferSharedMemoryName()
        let handle = try simulatorOpenSharedMemory(
            named: name,
            flags: O_CREAT | O_EXCL | O_RDWR
        )
        if handle >= 0 { return (name, handle) }
        guard errno == EEXIST else {
            throw SimulatorWorkerFailure.framebufferUnavailable(
                "Could not create the Simulator framebuffer ring: "
                    + "\(simulatorFramebufferErrnoDescription())."
            )
        }
    }
    throw SimulatorWorkerFailure.framebufferUnavailable(
        "Could not reserve a unique Simulator framebuffer ring name."
    )
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
