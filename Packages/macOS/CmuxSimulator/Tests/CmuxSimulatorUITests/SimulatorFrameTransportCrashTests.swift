import CoreVideo
import IOSurface
import Testing

@testable import CmuxSimulatorUI
@testable import CmuxSimulatorWorker

@Suite("Simulator frame transport crash containment")
struct SimulatorFrameTransportCrashTests {
    @Test("The host resolves unaligned phone-sized frame surfaces")
    func hostResolvesPhoneSizedSurfaces() throws {
        let producer = try SimulatorFramebufferSurfaceRing(width: 390, height: 844)

        let source = try SimulatorFrameSurfaceSource(descriptor: producer.descriptor)

        #expect(source.latestSurface == nil)
    }

    @Test("The host retains the last frame after its worker-owned producer disappears")
    func hostRetainsFrameAfterProducerRelease() throws {
        var producer: SimulatorFramebufferSurfaceRing? = try SimulatorFramebufferSurfaceRing(
            width: 2,
            height: 2
        )
        let source = try SimulatorFrameSurfaceSource(
            descriptor: try #require(producer).descriptor
        )
        let input = try makeInputSurface(pixel: 0xFF_33_22_11)

        try #require(producer).publish(input)
        #expect(readFirstPixel(try #require(source.latestSurface)) == 0xFF_33_22_11)

        producer = nil

        #expect(readFirstPixel(try #require(source.latestSurface)) == 0xFF_33_22_11)
    }

    private func makeInputSurface(pixel: UInt32) throws -> IOSurface {
        let properties: [String: Any] = [
            kIOSurfaceWidth as String: 2,
            kIOSurfaceHeight as String: 2,
            kIOSurfaceBytesPerElement as String: 4,
            kIOSurfacePixelFormat as String: kCVPixelFormatType_32BGRA,
        ]
        let surface = try #require(IOSurfaceCreate(properties as CFDictionary))
        IOSurfaceLock(surface, [], nil)
        defer { IOSurfaceUnlock(surface, [], nil) }
        let pixels = IOSurfaceGetBaseAddress(surface).assumingMemoryBound(to: UInt32.self)
        for index in 0..<4 {
            pixels[index] = pixel
        }
        return surface
    }

    private func readFirstPixel(_ surface: IOSurface) -> UInt32 {
        IOSurfaceLock(surface, [.readOnly], nil)
        defer { IOSurfaceUnlock(surface, [.readOnly], nil) }
        return IOSurfaceGetBaseAddress(surface)
            .assumingMemoryBound(to: UInt32.self)
            .pointee
    }
}
