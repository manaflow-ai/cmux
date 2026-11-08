import CmuxSimulator
import Foundation
import Testing
@testable import CmuxSimulatorUI

@Suite("Simulator camera source classification")
struct SimulatorCameraSourceClassifierTests {
    @Test("BMP, WebP, and extensionless images are detected by content")
    func contentDetection() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-camera-classifier-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let bmp = directory.appendingPathComponent("frame.bmp")
        let extensionless = directory.appendingPathComponent("frame")
        let webp = directory.appendingPathComponent("frame.webp")
        let bmpData = Self.onePixelBMP()
        try bmpData.write(to: bmp)
        try bmpData.write(to: extensionless)
        let webPData = try #require(Data(base64Encoded:
            "UklGRiIAAABXRUJQVlA4IBYAAAAwAQCdASoBAAEAAUAmJaQAA3AA/v89WAAAAA=="
        ))
        try webPData.write(to: webp)

        let classifier = SimulatorCameraSourceClassifier()
        #expect(await classifier.configuration(for: bmp) == .image(bmp))
        #expect(await classifier.configuration(for: extensionless) == .image(extensionless))
        #expect(await classifier.configuration(for: webp) == .image(webp))
    }

    private static func onePixelBMP() -> Data {
        Data([
            0x42, 0x4D, 58, 0, 0, 0, 0, 0, 0, 0, 54, 0, 0, 0,
            40, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 24, 0,
            0, 0, 0, 0, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0, 0x00, 0x00, 0xFF, 0x00,
        ])
    }
}
