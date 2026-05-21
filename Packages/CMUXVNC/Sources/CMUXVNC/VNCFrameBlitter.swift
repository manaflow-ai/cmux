import Foundation

public enum VNCFrameBlitter {
    public static func copyBGRAFrame(
        header: VNCFrameHeader,
        payload: Data,
        into framebuffer: inout Data,
        framebufferWidth: Int,
        framebufferHeight: Int
    ) -> Bool {
        guard header.pixelFormat == .bgra8,
              header.framebufferWidth == framebufferWidth,
              header.framebufferHeight == framebufferHeight,
              VNCFrameValidator.validate(header: header, payloadByteCount: payload.count) == nil else {
            return false
        }

        let (pixelCount, pixelOverflow) = framebufferWidth.multipliedReportingOverflow(by: framebufferHeight)
        let (expectedByteCount, expectedByteCountOverflow) = pixelCount.multipliedReportingOverflow(by: 4)
        guard !pixelOverflow,
              !expectedByteCountOverflow,
              framebuffer.count == expectedByteCount else {
            return false
        }

        let (rowBytes, rowBytesOverflow) = header.width.multipliedReportingOverflow(by: 4)
        guard !rowBytesOverflow else {
            return false
        }
        let payloadByteCount = payload.count
        let framebufferByteCount = framebuffer.count
        var didCopy = true

        payload.withUnsafeBytes { sourceBytes in
            guard let source = sourceBytes.bindMemory(to: UInt8.self).baseAddress else {
                didCopy = false
                return
            }
            framebuffer.withUnsafeMutableBytes { destinationBytes in
                guard let destination = destinationBytes.bindMemory(to: UInt8.self).baseAddress else {
                    didCopy = false
                    return
                }
                for row in 0..<header.height {
                    let (sourceOffset, sourceOverflow) = row.multipliedReportingOverflow(by: rowBytes)
                    let (destinationY, destinationYOverflow) = header.y.addingReportingOverflow(row)
                    let (destinationRowOffset, destinationRowOverflow) = destinationY
                        .multipliedReportingOverflow(by: framebufferWidth)
                    let (destinationPixelOffset, destinationPixelOverflow) = destinationRowOffset
                        .addingReportingOverflow(header.x)
                    let (destinationOffset, destinationByteOverflow) = destinationPixelOffset
                        .multipliedReportingOverflow(by: 4)
                    let (sourceEnd, sourceEndOverflow) = sourceOffset.addingReportingOverflow(rowBytes)
                    let (destinationEnd, destinationEndOverflow) = destinationOffset.addingReportingOverflow(rowBytes)
                    guard !sourceOverflow,
                          !destinationYOverflow,
                          !destinationRowOverflow,
                          !destinationPixelOverflow,
                          !destinationByteOverflow,
                          !sourceEndOverflow,
                          !destinationEndOverflow,
                          destinationOffset >= 0,
                          destinationEnd <= framebufferByteCount,
                          sourceOffset >= 0,
                          sourceEnd <= payloadByteCount else {
                        didCopy = false
                        return
                    }
                    destination.advanced(by: destinationOffset)
                        .update(from: source.advanced(by: sourceOffset), count: rowBytes)
                }
            }
        }
        return didCopy
    }
}
