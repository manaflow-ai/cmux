import CmuxSimulator
import CmuxSimulatorSystem
import Darwin
import Foundation
import notify

/// Read-only host mapping of one worker-published packed-BGRA frame ring.
///
/// Every successful read is a deep copy bracketed by acquire-loads of both the
/// publication word and per-slot version. Shared bytes never reach Core Animation.
// SAFETY: the descriptor, file descriptor, mapping, and layout are immutable.
// The mapping is read-only and remains alive for every call through `self`.
final class SimulatorFrameSurfaceSource: SimulatorFrameSurfaceReading, @unchecked Sendable {
    private let descriptorHandle: Int32
    private let mapping: UnsafeMutableRawPointer
    private let layout: SimulatorFrameSharedMemoryLayout
    private let byteCopier: any SimulatorFrameByteCopying
    private let framePublicationNotificationName: String
    private let framePublicationLock = NSLock()
    private var framePublicationToken: Int32?

    init(
        descriptor: SimulatorFrameTransportDescriptor,
        byteCopier: any SimulatorFrameByteCopying = SimulatorFrameByteCopier()
    ) throws {
        guard simulatorFrameSharedMemoryNameIsValid(descriptor.sharedMemoryName),
              let framePublicationNotificationName =
                descriptor.framePublicationNotificationName else {
            throw SimulatorFrameLayoutError("The worker supplied an invalid frame-ring name.")
        }
        let layout = try SimulatorFrameSharedMemoryLayout(descriptor: descriptor)
        guard cmux_simulator_atomic_u64_is_lock_free() else {
            throw SimulatorFrameLayoutError("Lock-free frame publication is unavailable.")
        }
        let handle = try simulatorOpenSharedMemory(
            named: descriptor.sharedMemoryName,
            flags: O_RDONLY
        )
        guard handle >= 0 else {
            throw SimulatorFrameLayoutError("The worker frame ring is unavailable.")
        }
        guard fcntl(handle, F_SETFD, FD_CLOEXEC) != -1 else {
            close(handle)
            throw SimulatorFrameLayoutError("The worker frame-ring descriptor is unsafe.")
        }
        var status = stat()
        guard fstat(handle, &status) == 0,
              status.st_uid == geteuid(),
              status.st_mode & (S_IRWXU | S_IRWXG | S_IRWXO)
                == (S_IRUSR | S_IWUSR),
              status.st_size == off_t(layout.totalByteCount) else {
            close(handle)
            throw SimulatorFrameLayoutError(
                "The worker frame ring has unsafe ownership, permissions, or size."
            )
        }
        guard
            let mapping = mmap(
                nil,
                layout.totalByteCount,
                PROT_READ,
                MAP_SHARED,
                handle,
                0
            ), mapping != MAP_FAILED
        else {
            close(handle)
            throw SimulatorFrameLayoutError("The worker frame ring could not be mapped read-only.")
        }
        guard layout.headerIsValid(at: UnsafeRawPointer(mapping)) else {
            munmap(mapping, layout.totalByteCount)
            close(handle)
            throw SimulatorFrameLayoutError("The worker frame-ring header is invalid.")
        }
        descriptorHandle = handle
        self.mapping = mapping
        self.layout = layout
        self.byteCopier = byteCopier
        self.framePublicationNotificationName = framePublicationNotificationName
    }

    deinit {
        cancelFramePublicationHandler()
        munmap(mapping, layout.totalByteCount)
        close(descriptorHandle)
    }

    @discardableResult
    func setFramePublicationHandler(
        _ handler: (@Sendable () -> Void)?
    ) -> Bool {
        framePublicationLock.withLock {
            if let framePublicationToken {
                notify_cancel(framePublicationToken)
                self.framePublicationToken = nil
            }
            guard let handler else { return true }
            var token: Int32 = 0
            let status = notify_register_dispatch(
                framePublicationNotificationName,
                &token,
                DispatchQueue.global(qos: .userInteractive)
            ) { _ in
                handler()
            }
            guard status == NOTIFY_STATUS_OK else { return false }
            framePublicationToken = token
            return true
        }
    }

    private func cancelFramePublicationHandler() {
        framePublicationLock.withLock {
            guard let framePublicationToken else { return }
            notify_cancel(framePublicationToken)
            self.framePublicationToken = nil
        }
    }

    func hasPublishedFrame(after sequence: UInt64?) -> Bool {
        let word = Int64(bitPattern: cmux_simulator_atomic_load_u64_acquire(
            layout.publishedWordPointer(in: mapping)
        ))
        guard let published = layout.decodePublishedWord(word) else { return false }
        return sequence.map { published.sequence > $0 } ?? true
    }

    func copyLatestFrame(after sequence: UInt64?) async -> SimulatorFrameSnapshot? {
        let publicationPointer = layout.publishedWordPointer(in: mapping)
        let firstWord = Int64(bitPattern: cmux_simulator_atomic_load_u64_acquire(
            publicationPointer
        ))
        guard let published = layout.decodePublishedWord(firstWord),
              sequence.map({ published.sequence > $0 }) ?? true,
              let expectedVersion = layout.completedSlotVersion(
                frameSequence: published.sequence
              ),
              let versionPointer = layout.slotVersionPointer(
                slot: published.slot,
                in: mapping
              ),
              let slotBytes = layout.slotBytes(
                slot: published.slot,
                in: UnsafeRawPointer(mapping)
              ) else { return nil }
        let firstVersion = Int64(bitPattern: cmux_simulator_atomic_load_u64_acquire(
            versionPointer
        ))
        guard firstVersion == expectedVersion, firstVersion.isMultiple(of: 2) else {
            return nil
        }

        guard let pixels = await byteCopier.copyBytes(
            from: slotBytes,
            count: layout.slotByteCount
        ) else { return nil }
        // A trailing acquire load does not order the pixel reads that precede
        // it. Keep the complete copy before both seqlock retry loads.
        cmux_simulator_atomic_thread_fence_seq_cst()

        let secondVersion = Int64(bitPattern: cmux_simulator_atomic_load_u64_acquire(
            versionPointer
        ))
        let secondWord = Int64(bitPattern: cmux_simulator_atomic_load_u64_acquire(
            publicationPointer
        ))
        guard firstVersion == secondVersion,
              firstWord == secondWord else { return nil }
        return SimulatorFrameSnapshot(
            pixels: pixels,
            width: layout.width,
            height: layout.height,
            bytesPerRow: layout.bytesPerRow,
            sequence: published.sequence
        )
    }
}
