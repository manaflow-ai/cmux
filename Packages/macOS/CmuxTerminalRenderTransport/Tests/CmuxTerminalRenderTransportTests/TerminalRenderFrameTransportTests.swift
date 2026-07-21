import CoreFoundation
import Foundation
import IOSurface
import Testing
@testable import CmuxTerminalRenderTransport

@Suite(.serialized) struct TerminalRenderFrameTransportTests {
    @Test func securelyTransfersIOSurfaceAndMetadata() throws {
        let token = Data((0..<16).map(UInt8.init))
        let receiver = try TerminalRenderFrameReceiver(
            authenticationToken: token
        )
        let sender = try TerminalRenderFrameSender(endpoint: receiver.endpoint)
        let surface = makeSurface(width: 32, height: 24)
        let metadata = TerminalRenderFrameMetadata(
            surfaceID: UUID(uuidString: "184DCEB4-F88C-4A9D-89F4-03087E606B8B")!,
            workerGeneration: 7,
            surfaceGeneration: 4,
            frameSequence: 19,
            width: 32,
            height: 24
        )

        #expect(try sender.send(surface: surface, metadata: metadata))
        let received = try receiver.receiveOne(timeoutMilliseconds: 1_000)
        #expect(received?.metadata == metadata)
        #expect(received.map { IOSurfaceGetWidth($0.surface) } == 32)
        #expect(received.map { IOSurfaceGetHeight($0.surface) } == 24)
    }

    @Test func rejectsFrameWithWrongAuthenticationToken() throws {
        let receiver = try TerminalRenderFrameReceiver(
            authenticationToken: Data(repeating: 0x11, count: 16)
        )
        let wrongEndpoint = try TerminalRenderFrameEndpoint(
            serviceName: receiver.endpoint.serviceName,
            authenticationToken: Data(repeating: 0x22, count: 16)
        )
        let sender = try TerminalRenderFrameSender(endpoint: wrongEndpoint)
        let surface = makeSurface(width: 4, height: 4)
        let metadata = TerminalRenderFrameMetadata(
            surfaceID: UUID(),
            workerGeneration: 8,
            surfaceGeneration: 1,
            frameSequence: 1,
            width: 4,
            height: 4
        )

        #expect(try sender.send(surface: surface, metadata: metadata))
        #expect(throws: TerminalRenderFrameTransportError.invalidMessage) {
            try receiver.receiveOne(timeoutMilliseconds: 1_000)
        }
    }

    private func makeSurface(width: Int, height: Int) -> IOSurfaceRef {
        let bytesPerRow = width * 4
        let properties: [CFString: Any] = [
            kIOSurfaceWidth: width,
            kIOSurfaceHeight: height,
            kIOSurfaceBytesPerElement: 4,
            kIOSurfaceBytesPerRow: bytesPerRow,
            kIOSurfaceAllocSize: bytesPerRow * height,
        ]
        return IOSurfaceCreate(properties as CFDictionary)!
    }
}
