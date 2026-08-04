import CmuxSimulator
import Darwin

struct ApplicationSurfaceSessionDescriptor: Equatable, Sendable {
    private static let frameHeaderByteCount = 64
    private static let framePixelByteCount = 4
    private static let frameSlotCount = 3
    private static let maximumFrameWidth = 4_096
    private static let maximumFrameHeight = 2_304
    private static let maximumFrameSlotByteCount = 16 * 1_024 * 1_024
    private static let maximumCopyByteCountPerSecond = 512 * 1_024 * 1_024

    let sessionID: String
    let targetWindowID: UInt32?
    let processIdentity: ApplicationSurfaceProcessIdentity?
    let frameTransport: SimulatorFrameTransportDescriptor
    let maximumPresentationFramesPerSecond: Int

    init(
        sessionID: String,
        targetWindowID: UInt32? = nil,
        processIdentity: ApplicationSurfaceProcessIdentity? = nil,
        frameTransport: SimulatorFrameTransportDescriptor,
        maximumPresentationFramesPerSecond: Int = 60
    ) {
        self.sessionID = sessionID
        self.targetWindowID = targetWindowID
        self.processIdentity = processIdentity
        self.frameTransport = frameTransport
        self.maximumPresentationFramesPerSecond =
            maximumPresentationFramesPerSecond
    }

    static func validatedPresentationFramesPerSecond(
        for descriptor: SimulatorFrameTransportDescriptor,
        requestedFramesPerSecond: Int
    ) -> Int? {
        guard (1...120).contains(requestedFramesPerSecond),
              (1...maximumFrameWidth).contains(descriptor.width),
              (1...maximumFrameHeight).contains(descriptor.height) else {
            return nil
        }
        let (expectedBytesPerRow, rowOverflow) = descriptor.width
            .multipliedReportingOverflow(by: framePixelByteCount)
        let (slotByteCount, slotOverflow) = expectedBytesPerRow
            .multipliedReportingOverflow(by: descriptor.height)
        let (ringByteCount, ringOverflow) = slotByteCount
            .multipliedReportingOverflow(by: frameSlotCount)
        let (unalignedByteCount, headerOverflow) = frameHeaderByteCount
            .addingReportingOverflow(ringByteCount)
        guard !rowOverflow,
              !slotOverflow,
              !ringOverflow,
              !headerOverflow,
              slotByteCount > 0,
              slotByteCount <= maximumFrameSlotByteCount,
              descriptor.bytesPerRow == expectedBytesPerRow,
              descriptor.slotCount == frameSlotCount else {
            return nil
        }
        let pageByteCount = Int(getpagesize())
        guard pageByteCount > 0 else { return nil }
        let remainder = unalignedByteCount % pageByteCount
        let paddingByteCount = remainder == 0
            ? 0
            : pageByteCount - remainder
        let (expectedSharedMemoryByteCount, alignmentOverflow) =
            unalignedByteCount.addingReportingOverflow(paddingByteCount)
        guard !alignmentOverflow,
              descriptor.sharedMemoryByteCount
                == expectedSharedMemoryByteCount else {
            return nil
        }
        let bandwidthFramesPerSecond = max(
            1,
            min(
                120,
                maximumCopyByteCountPerSecond / slotByteCount
            )
        )
        return min(requestedFramesPerSecond, bandwidthFramesPerSecond)
    }
}
