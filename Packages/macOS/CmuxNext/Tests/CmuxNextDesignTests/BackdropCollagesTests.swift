@testable import CmuxNextDesign
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

/// Collages (backgrounds plan phase 7): `collage:<id>` names one safely; saving draws the layers
/// over the fill at 3200x2000 and lists it; an edit gets a new id and drops the old files; a
/// layer must be a still picture on the canvas; nothing readable is refused.
@Suite struct BackdropCollagesTests {
    static func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-collages-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func png(_ red: CGFloat, to url: URL) throws {
        let context = try #require(CGContext(data: nil, width: 40, height: 30, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: red, green: 0.2, blue: 0.3, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    @Test func aCollageIdIsSafeAndRoundTrips() {
        #expect(BackdropSelection(id: "collage:c-2f9a1b7c04de") == .collage(id: "c-2f9a1b7c04de"))
        #expect(BackdropSelection.collage(id: "c-1").id == "collage:c-1")
        for bad in ["collage:", "collage:../evil", "collage:a/b", "collage:" + String(repeating: "a", count: 65)] {
            #expect(BackdropSelection(id: bad) == nil, "\(bad) parsed")
        }
        #expect(!BackdropSelection.collage(id: "c-1").isVideo)
        #expect(BackdropSelection.collage(id: "c-1").pickerCollection?.id == BackdropCollages.collection)
    }

    @Test func savingDrawsListsAndAnEditReplaces() throws {
        let pictures = try Self.folder(), collages = BackdropCollages(folder: try Self.folder())
        let red = pictures.appendingPathComponent("red.png"), blue = pictures.appendingPathComponent("blue.png")
        try Self.png(1, to: red)
        try Self.png(0, to: blue)
        let collage = BackdropCollage(name: "Pair", fill: "#202020", layers: [
            .init(source: "file:\(red.path)", x: 0.02, y: 0.02, width: 0.47, height: 0.96),
            .init(source: "file:\(blue.path)", x: 0.51, y: 0.02, width: 0.47, height: 0.96, cornerRadius: 0.1),
        ])
        let id = try collages.save(collage)
        let png = try #require(collages.imageURL(id))
        let image = try #require(CGImageSourceCreateWithURL(png as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        #expect(image.width == 3200 && image.height == 2000)
        #expect(collages.collage(id) == collage)
        #expect(collages.list() == [.collage(id: id)])
        // An edit is a new drawing under a new id; the old files go.
        var edited = collage
        edited.name = "Pair 2"
        let next = try collages.save(edited, replacing: id)
        #expect(next != id && collages.collage(id) == nil && collages.list() == [.collage(id: next)])
        try collages.delete(next)
        #expect(collages.list().isEmpty)
    }

    @Test func onlyStillPicturesOnTheCanvasMayBeLayers() throws {
        let pictures = try Self.folder(), collages = BackdropCollages(folder: try Self.folder())
        let red = pictures.appendingPathComponent("red.png")
        try Self.png(1, to: red)
        let good = BackdropCollage.Layer(source: "file:\(red.path)", x: 0, y: 0, width: 0.5, height: 0.5)
        var offCanvas = good
        offCanvas.x = 3
        var nan = good
        nan.width = .nan
        let invalid: [BackdropCollage] = [
            .init(name: "", layers: [.init(source: "desktop", x: 0, y: 0, width: 0.5, height: 0.5)]),
            .init(name: "", layers: [.init(source: "file:/tmp/clip.mov", x: 0, y: 0, width: 0.5, height: 0.5)]),
            .init(name: "", layers: [.init(source: "collage:c-1", x: 0, y: 0, width: 0.5, height: 0.5)]),
            .init(name: "", layers: [offCanvas]),
            .init(name: "", layers: [nan]),
            .init(name: "", fill: "red", layers: [good]),
            .init(name: "", layers: Array(repeating: good, count: BackdropCollages.maximumLayers + 1)),
        ]
        for collage in invalid {
            #expect(throws: BackdropCollages.SaveError.invalid) { try collages.save(collage) }
        }
        // Valid, but nothing readable: refused rather than saving a bare fill.
        let missing = BackdropCollage(name: "", layers: [.init(source: "file:/nowhere/gone.png", x: 0, y: 0, width: 0.5, height: 0.5)])
        #expect(throws: BackdropCollages.SaveError.noPictures) { try collages.save(missing) }
        #expect(collages.list().isEmpty)
    }

    @Test func theCatalogListsCollagesAfterYourImages() throws {
        let backgrounds = try Self.folder()
        let pictures = try Self.folder()
        let red = pictures.appendingPathComponent("red.png")
        try Self.png(1, to: red)
        let images = BackdropUserImages(folder: backgrounds)
        let mine = try images.adopt(red)
        let collages = BackdropCollages(folder: backgrounds.appendingPathComponent("Collages", isDirectory: true))
        let id = try collages.save(.init(name: "One", layers: [.init(source: mine.id, x: 0, y: 0, width: 1, height: 1)]))
        let catalog = BackdropCatalog(systemDirectory: try Self.folder(), fileManager: .default, userImages: images,
                                      aerials: try Self.folder())
        let mineIndex = try #require(catalog.choices.firstIndex(of: mine))
        let collageIndex = try #require(catalog.choices.firstIndex(of: .collage(id: id)))
        #expect(collageIndex == mineIndex + 1)
        #expect(!images.list().contains(.collage(id: id)), "a collage was listed as one of your images")
    }
}
