internal import CmuxTerminalRenderProtocol
internal import CmuxTerminalRenderTransport
internal import CoreFoundation
internal import Darwin
internal import Foundation
internal import IOSurface

@main
struct TerminalRenderTestSender {
    static func main() async {
        guard CommandLine.arguments.count == 4,
              let capability = Data(base64Encoded: CommandLine.arguments[2]),
              let encodedMetadata = Data(base64Encoded: CommandLine.arguments[3]),
              let metadata = try? TerminalRenderFrameMetadataCodec().decode(encodedMetadata),
              let endpoint = try? TerminalRenderFrameEndpoint(
                  serviceName: CommandLine.arguments[1],
                  capability: capability
              ) else {
            exit(64)
        }

        let bytesPerElement = metadata.pixelFormat == .rgba16Float ? 8 : 4
        let bytesPerRow = Int(metadata.width) * bytesPerElement
        let properties: [CFString: Any] = [
            kIOSurfaceWidth: metadata.width,
            kIOSurfaceHeight: metadata.height,
            kIOSurfaceBytesPerElement: bytesPerElement,
            kIOSurfaceBytesPerRow: bytesPerRow,
            kIOSurfaceAllocSize: bytesPerRow * Int(metadata.height),
            kIOSurfacePixelFormat: metadata.pixelFormat.rawValue,
        ]
        guard let rawSurface = IOSurfaceCreate(properties as CFDictionary),
              let sender = try? TerminalRenderFrameSender(endpoint: endpoint) else {
            exit(70)
        }

        do {
            let delivery = try await sender.send(
                surface: TerminalRenderSurfaceHandle(surface: rawSurface),
                metadata: metadata
            )
            await sender.stop()
            exit(delivery == .sent ? 0 : 75)
        } catch {
            exit(74)
        }
    }
}
