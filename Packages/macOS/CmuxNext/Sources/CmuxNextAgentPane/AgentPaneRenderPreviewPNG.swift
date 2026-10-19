import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Encodes on a worker task, with a 1x raster and room below the agent's base64 limit (Lucas 2026-10-19).
struct AgentPaneRenderPreviewPNG {
    nonisolated init() {}

    nonisolated func encode(_ image: CGImage, width: Int, height: Int, report: Data) throws -> String {
        var scale = min(1, 1568 / Double(max(width, height)))
        // Each pass shrinks by 0.8; 24 passes reach 0.5% scale, far below the 3 MiB limit.
        for _ in 0..<24 {
            let w = max(1, Int(Double(width) * scale)), h = max(1, Int(Double(height) * scale))
            guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw AgentPaneRenderPreviewError.failed
            }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            let data = NSMutableData()
            guard let raster = context.makeImage(),
                  let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
                throw AgentPaneRenderPreviewError.failed
            }
            CGImageDestinationAddImage(destination, raster, nil)
            guard CGImageDestinationFinalize(destination) else { throw AgentPaneRenderPreviewError.failed }
            if data.length <= 3 << 20 {
                var result = try JSONSerialization.jsonObject(with: report) as? [String: Any] ?? [:]
                result["png"] = (data as Data).base64EncodedString()
                result["width"] = w
                result["capturedHeight"] = h
                return String(decoding: try JSONSerialization.data(withJSONObject: result), as: UTF8.self)
            }
            scale *= 0.8
        }
        throw AgentPaneRenderPreviewError.failed
    }
}
