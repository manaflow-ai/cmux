import Darwin
import Foundation

actor SharedFrameBuffer {
    private static let maximumFrameBytes = 64 * 1024 * 1024
    let slotSize: Int
    let slotCount: Int
    let path: String

    private let descriptor: Int32
    private let baseAddress: UnsafeMutableRawPointer
    private let byteCount: Int
    private var availableSlots: Set<Int>

    init(path: String, maximumWidth: Int, maximumHeight: Int, slotCount: Int) throws {
        let (pixels, pixelOverflow) = maximumWidth.multipliedReportingOverflow(by: maximumHeight)
        let (slotSize, slotOverflow) = pixels.multipliedReportingOverflow(by: 4)
        let (byteCount, totalOverflow) = slotSize.multipliedReportingOverflow(by: slotCount)
        guard maximumWidth > 0, maximumHeight > 0, slotCount > 0,
              !pixelOverflow, !slotOverflow, !totalOverflow,
              slotSize <= Self.maximumFrameBytes else {
            throw BridgeFailure.invalidArguments
        }
        self.path = path
        self.slotCount = slotCount
        self.slotSize = slotSize
        self.byteCount = byteCount
        self.availableSlots = Set(0 ..< slotCount)

        let descriptor = open(path, O_RDWR | O_CREAT | O_TRUNC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw BridgeFailure.systemCall("open", errno) }
        self.descriptor = descriptor
        guard ftruncate(descriptor, off_t(byteCount)) == 0 else {
            close(descriptor)
            throw BridgeFailure.systemCall("ftruncate", errno)
        }
        guard let mapping = mmap(nil, byteCount, PROT_READ | PROT_WRITE, MAP_SHARED, descriptor, 0),
              mapping != MAP_FAILED else {
            close(descriptor)
            throw BridgeFailure.systemCall("mmap", errno)
        }
        self.baseAddress = mapping
    }

    deinit {
        munmap(baseAddress, byteCount)
        close(descriptor)
    }

    func store(_ frame: Android_Emulation_Control_Image) throws -> Int? {
        guard let slot = availableSlots.min() else { return nil }
        let width = Int(frame.format.width)
        let height = Int(frame.format.height)
        let (pixels, pixelOverflow) = width.multipliedReportingOverflow(by: height)
        let (expectedBytes, byteOverflow) = pixels.multipliedReportingOverflow(by: 4)
        guard width > 0, height > 0,
              !pixelOverflow, !byteOverflow,
              expectedBytes <= slotSize,
              frame.image.count == expectedBytes else {
            throw BridgeFailure.invalidFrame(width: width, height: height, bytes: frame.image.count)
        }
        availableSlots.remove(slot)
        frame.image.withUnsafeBytes { source in
            guard let sourceAddress = source.baseAddress else { return }
            memcpy(baseAddress.advanced(by: slot * slotSize), sourceAddress, expectedBytes)
        }
        return slot
    }

    func release(slot: Int) {
        guard (0 ..< slotCount).contains(slot) else { return }
        availableSlots.insert(slot)
    }
}
