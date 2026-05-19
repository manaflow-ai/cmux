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

        let expectedByteCount = framebufferWidth * framebufferHeight * 4
        guard framebuffer.count == expectedByteCount else {
            return false
        }

        let rowBytes = header.width * 4
        let payloadByteCount = payload.count
        let framebufferByteCount = framebuffer.count

        payload.withUnsafeBytes { sourceBytes in
            guard let source = sourceBytes.bindMemory(to: UInt8.self).baseAddress else { return }
            framebuffer.withUnsafeMutableBytes { destinationBytes in
                guard let destination = destinationBytes.bindMemory(to: UInt8.self).baseAddress else { return }
                for row in 0..<header.height {
                    let sourceOffset = row * rowBytes
                    let destinationOffset = ((header.y + row) * framebufferWidth + header.x) * 4
                    guard destinationOffset >= 0,
                          destinationOffset + rowBytes <= framebufferByteCount,
                          sourceOffset >= 0,
                          sourceOffset + rowBytes <= payloadByteCount else {
                        return
                    }
                    destination.advanced(by: destinationOffset)
                        .update(from: source.advanced(by: sourceOffset), count: rowBytes)
                }
            }
        }
        return true
    }
}
