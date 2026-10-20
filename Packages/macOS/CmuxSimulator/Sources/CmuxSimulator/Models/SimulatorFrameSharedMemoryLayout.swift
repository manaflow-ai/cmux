import Darwin
import Foundation

private let frameHeaderByteCount = 64
private let framePublishedWordOffset = 32
private let frameSlotVersionOffset = 40
private let frameSlotVersionStride = 8
private let frameMagic: UInt32 = 0x434D_5846
private let frameVersion: UInt32 = 2
private let framePixelByteCount = 4
private let frameRingSlotCount = 3
private let maximumFrameDimension = 16_384
private let maximumFrameRingByteCount = 256 * 1_024 * 1_024

/// Validated memory geometry for the packed-BGRA framebuffer protocol.
package struct SimulatorFrameSharedMemoryLayout: Sendable {
    /// Frame width in pixels.
    package let width: Int
    /// Frame height in pixels.
    package let height: Int
    /// Packed BGRA bytes in one row.
    package let bytesPerRow: Int
    /// Bytes in one frame slot.
    package let slotByteCount: Int
    /// Fixed number of slots in the ring.
    package let slotCount: Int
    /// Exact header and pixel mapping size.
    package let totalByteCount: Int

    /// Creates the fixed triple-ring layout for a framebuffer size.
    package init(width: Int, height: Int) throws {
        guard (1...maximumFrameDimension).contains(width),
              (1...maximumFrameDimension).contains(height) else {
            throw SimulatorFrameLayoutError("Framebuffer dimensions are outside supported bounds.")
        }
        let (bytesPerRow, rowOverflow) = width.multipliedReportingOverflow(by: framePixelByteCount)
        let (slotByteCount, slotOverflow) = bytesPerRow.multipliedReportingOverflow(by: height)
        let (ringByteCount, ringOverflow) = slotByteCount.multipliedReportingOverflow(
            by: frameRingSlotCount
        )
        let (unalignedTotalByteCount, totalOverflow) = frameHeaderByteCount.addingReportingOverflow(
            ringByteCount
        )
        guard !rowOverflow,
              !slotOverflow,
              !ringOverflow,
              !totalOverflow else {
            throw SimulatorFrameLayoutError("Framebuffer byte geometry exceeds supported bounds.")
        }
        let pageByteCount = Int(getpagesize())
        guard pageByteCount > 0 else {
            throw SimulatorFrameLayoutError("Framebuffer page geometry is unavailable.")
        }
        let remainder = unalignedTotalByteCount % pageByteCount
        let paddingByteCount = remainder == 0 ? 0 : pageByteCount - remainder
        let (totalByteCount, alignmentOverflow) = unalignedTotalByteCount
            .addingReportingOverflow(paddingByteCount)
        guard !alignmentOverflow,
              totalByteCount <= maximumFrameRingByteCount else {
            throw SimulatorFrameLayoutError("Framebuffer byte geometry exceeds supported bounds.")
        }
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.slotByteCount = slotByteCount
        slotCount = frameRingSlotCount
        self.totalByteCount = totalByteCount
    }

    /// Validates a transport descriptor against the fixed packed-frame layout.
    package init(descriptor: SimulatorFrameTransportDescriptor) throws {
        let expected = try SimulatorFrameSharedMemoryLayout(
            width: descriptor.width,
            height: descriptor.height
        )
        guard descriptor.bytesPerRow == expected.bytesPerRow,
              descriptor.slotCount == expected.slotCount,
              descriptor.sharedMemoryByteCount == expected.totalByteCount else {
            throw SimulatorFrameLayoutError("Framebuffer descriptor geometry is inconsistent.")
        }
        self = expected
    }

    /// Writes a versioned empty header into a newly zeroed mapping.
    package func initializeHeader(at mapping: UnsafeMutableRawPointer) {
        memset(mapping, 0, frameHeaderByteCount)
        mapping.storeBytes(of: frameMagic, toByteOffset: 0, as: UInt32.self)
        mapping.storeBytes(of: frameVersion, toByteOffset: 4, as: UInt32.self)
        mapping.storeBytes(of: UInt32(width), toByteOffset: 8, as: UInt32.self)
        mapping.storeBytes(of: UInt32(height), toByteOffset: 12, as: UInt32.self)
        mapping.storeBytes(of: UInt32(bytesPerRow), toByteOffset: 16, as: UInt32.self)
        mapping.storeBytes(of: UInt32(slotCount), toByteOffset: 20, as: UInt32.self)
        mapping.storeBytes(of: UInt64(totalByteCount), toByteOffset: 24, as: UInt64.self)
    }

    /// Confirms that a mapped header matches this validated layout.
    package func headerIsValid(at mapping: UnsafeRawPointer) -> Bool {
        mapping.load(fromByteOffset: 0, as: UInt32.self) == frameMagic
            && mapping.load(fromByteOffset: 4, as: UInt32.self) == frameVersion
            && mapping.load(fromByteOffset: 8, as: UInt32.self) == UInt32(width)
            && mapping.load(fromByteOffset: 12, as: UInt32.self) == UInt32(height)
            && mapping.load(fromByteOffset: 16, as: UInt32.self) == UInt32(bytesPerRow)
            && mapping.load(fromByteOffset: 20, as: UInt32.self) == UInt32(slotCount)
            && mapping.load(fromByteOffset: 24, as: UInt64.self) == UInt64(totalByteCount)
    }

    /// Returns the aligned publication-word pointer.
    package func publishedWordPointer(
        in mapping: UnsafeMutableRawPointer
    ) -> UnsafeMutablePointer<Int64> {
        mapping.advanced(by: framePublishedWordOffset).assumingMemoryBound(to: Int64.self)
    }

    /// Returns one aligned per-slot version pointer.
    package func slotVersionPointer(
        slot: Int,
        in mapping: UnsafeMutableRawPointer
    ) -> UnsafeMutablePointer<Int64>? {
        guard (0..<slotCount).contains(slot) else { return nil }
        return mapping
            .advanced(by: frameSlotVersionOffset + slot * frameSlotVersionStride)
            .assumingMemoryBound(to: Int64.self)
    }

    /// Returns the beginning of one packed pixel slot.
    package func slotBytes(
        slot: Int,
        in mapping: UnsafeRawPointer
    ) -> UnsafeRawPointer? {
        guard (0..<slotCount).contains(slot) else { return nil }
        return mapping.advanced(by: frameHeaderByteCount + slot * slotByteCount)
    }

    /// Encodes a positive frame sequence and slot in one atomic publication word.
    package func publishedWord(frameSequence: UInt64, slot: Int) -> Int64? {
        guard frameSequence > 0,
              frameSequence <= UInt64(Int64.max) >> 2,
              (0..<slotCount).contains(slot) else { return nil }
        return Int64((frameSequence << 2) | UInt64(slot))
    }

    /// Decodes an atomic publication word into its frame sequence and slot.
    package func decodePublishedWord(_ word: Int64) -> (sequence: UInt64, slot: Int)? {
        guard word > 0 else { return nil }
        let value = UInt64(word)
        let slot = Int(value & 0b11)
        let sequence = value >> 2
        guard sequence > 0, (0..<slotCount).contains(slot) else { return nil }
        return (sequence, slot)
    }

    /// Returns the even completed-version value for a frame sequence.
    package func completedSlotVersion(frameSequence: UInt64) -> Int64? {
        guard frameSequence > 0,
              frameSequence <= UInt64(Int64.max) / 2 else { return nil }
        return Int64(frameSequence * 2)
    }
}
