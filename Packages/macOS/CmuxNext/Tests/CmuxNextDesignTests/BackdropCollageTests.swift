import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import CmuxNextDesign

@Suite
nonisolated struct BackdropCollageTests {
    private let red = "file:/approved/red.png"
    private let blue = "file:/approved/blue.png"

    @Test func validatesGeometryAndStillSources() throws {
        let layer = BackdropCollage.Layer(source: red, x: 0, y: 0, width: 1, height: 1)
        try BackdropCollage(name: "Pictures", layers: [layer]).validate()
        var invalid = layer
        for value in [Double.nan, .infinity, -0.1, 1.1] {
            invalid.x = value
            #expect(throws: BackdropCollage.Failure.invalid) {
                try BackdropCollage(name: "Pictures", layers: [invalid]).validate()
            }
        }
        for source in ["desktop", "collage:c-other", "file:/approved/movie.mov", "file:relative.png"] {
            invalid = layer
            invalid.source = source
            #expect(throws: BackdropCollage.Failure.invalid) {
                try BackdropCollage(name: "Pictures", layers: [invalid]).validate()
            }
        }
        for change: (inout BackdropCollage.Layer) -> Void in [
            { $0.width = 0 }, { $0.height = 2 }, { $0.opacity = -0.1 },
            { $0.cornerRadius = 0.6 }, { $0.opacity = 0 },
        ] {
            invalid = layer
            change(&invalid)
            #expect(throws: BackdropCollage.Failure.invalid) {
                try BackdropCollage(name: "Pictures", layers: [invalid]).validate()
            }
        }
        for collage in [
            BackdropCollage(name: "Empty", layers: []),
            BackdropCollage(name: "Invalid fill", fill: "red", layers: [layer]),
            BackdropCollage(name: String(repeating: "x", count: 101), layers: [layer]),
            BackdropCollage(name: "Too many", layers: Array(repeating: layer, count: 13)),
        ] {
            #expect(throws: BackdropCollage.Failure.invalid) { try collage.validate() }
        }
    }

    @Test func rendersFillTopLeftCoordinatesLayerOrderOpacityAndRounding() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let sources = [red: try picture(in: folder, name: "red", red: 1, blue: 0),
                       blue: try picture(in: folder, name: "blue", red: 0, blue: 1)]
        let renderer = BackdropCollageRenderer(sources: sources)
        let collage = BackdropCollage(name: "Layers", fill: "#00FF00", layers: [
            .init(source: red, x: 0, y: 0, width: 0.5, height: 0.5),
            .init(source: blue, x: 0, y: 0, width: 0.5, height: 0.5, opacity: 0.5, cornerRadius: 0.5),
        ])
        let image = try renderer.render(collage)
        #expect(image.width == 3200)
        #expect(image.height == 2000)
        let middle = try pixel(image, x: 800, y: 500)
        #expect(abs(Int(middle[0]) - 127) <= 2)
        #expect(abs(Int(middle[2]) - 128) <= 2)
        #expect(try pixel(image, x: 10, y: 10) == [255, 0, 0, 255])
        #expect(try pixel(image, x: 3000, y: 1800) == [0, 255, 0, 255])
    }

    @Test func refusesUnapprovedOrUnreadableLayersWithoutPartialSave() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try picture(in: folder, name: "red", red: 1, blue: 0)
        let store = BackdropCollageStore(folder: folder.appendingPathComponent("Collages"))
        let collage = BackdropCollage(name: "Both required", layers: [
            .init(source: red, x: 0, y: 0, width: 0.5, height: 1),
            .init(source: blue, x: 0.5, y: 0, width: 0.5, height: 1),
        ])
        await #expect(throws: BackdropCollage.Failure.sourceNotAllowed(blue)) {
            try await store.save(collage, sources: [red: source])
        }
        await #expect(throws: BackdropCollage.Failure.unreadableSource(blue)) {
            try await store.save(collage, sources: [red: source, blue: folder.appendingPathComponent("missing.png")])
        }
        #expect(try await store.list().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("Collages").path))
    }

    @Test func savesNewIdentitiesAndDeletesOnlyTheRequestedRecord() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try picture(in: folder, name: "red", red: 1, blue: 0)
        let store = BackdropCollageStore(folder: folder.appendingPathComponent("Collages"))
        let collage = BackdropCollage(name: "Pictures", layers: [.init(source: red, x: 0, y: 0, width: 1, height: 1)])
        let first = try await store.save(collage, sources: [red: source])
        let second = try await store.save(collage, sources: [red: source])
        #expect(first != second)
        #expect(try await store.load(first) == collage)
        #expect(try await store.list() == [first, second].sorted())
        let image = try #require(CGImageSourceCreateWithURL(try await store.imageURL(first) as CFURL, nil))
        #expect(CGImageSourceGetCount(image) == 1)
        try await store.delete(first)
        #expect(try await store.list() == [second])
        #expect(try await store.load(second) == collage)
    }

    @Test func rejectsPathTraversalAndHidesIncompleteCorruptOrLinkedPairs() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = BackdropCollageStore(folder: folder)
        for id in ["", "../outside", "a/b", "é", String(repeating: "x", count: 65)] {
            await #expect(throws: BackdropCollage.Failure.invalid) { try await store.delete(id) }
        }
        try Data("{}".utf8).write(to: folder.appendingPathComponent("broken.json"))
        _ = try picture(in: folder, name: "broken", red: 1, blue: 0)
        let collage = BackdropCollage(name: "Pictures", layers: [.init(source: red, x: 0, y: 0, width: 1, height: 1)])
        try JSONEncoder().encode(collage).write(to: folder.appendingPathComponent("incomplete.json"))
        try JSONEncoder().encode(collage).write(to: folder.appendingPathComponent("linked.json"))
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("linked.png"),
                                                 withDestinationURL: folder.appendingPathComponent("broken.png"))
        #expect(try await store.list().isEmpty)
    }

    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func picture(in folder: URL, name: String, red: CGFloat, blue: CGFloat) throws -> URL {
        let context = try #require(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                                           space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: red, green: 0, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        let image = try #require(context.makeImage())
        let url = folder.appendingPathComponent(name + ".png")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        let crop = try #require(image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)))
        var bytes = [UInt8](repeating: 0, count: 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                               space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return bytes
    }
}
