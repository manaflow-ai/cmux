import CmuxNextDesign
import CmuxNextPages
import CmuxNextSettings
import CoreGraphics
import Foundation
import ImageIO
import Testing

/// The Settings page's own-background ops (`cmux.settings.backdrop.image.*`): a link refused by
/// its scheme comes back as the code the page words, only the folder's own images can be removed
/// or revealed, and Show in Finder with no image reveals the folder.
@MainActor @Suite struct BackdropImagesPageProviderTests {
    static let context = PageCallContext(page: "cmux.settings")

    @Test func theOpsServeOnlyTheFoldersOwnImages() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-own-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let images = BackdropUserImages(folder: folder)
        try Data(repeating: 1, count: 1000).write(to: images.folder.appendingPathComponent("Sea.png"))
        var revealed: [[URL]] = []
        var used: [URL] = []
        var current: BackdropSelection?
        let provider = BackdropImagesPageProvider(images: images, use: { used.append($0); return "file:\($0.path)" },
                                                  inUse: { current }, reveal: { revealed.append($0) })
        let call = { (op: String, params: JSONValue) in
            try await provider.call(BackdropImagesPageProvider.prefix + op, params: params, context: Self.context)
        }

        #expect(try await call("usage", [:])["bytes"]?.doubleValue == 1000)
        do {
            _ = try await call("link", ["url": "http://example.com/a.png"])
            Issue.record("an http link was downloaded")
        } catch let error as PageError {
            #expect(error.code == BackdropUserImages.ImportError.notHTTPS.code)
        }
        #expect(used.isEmpty)

        let own = "file:\(images.folder.appendingPathComponent("Sea.png").path)"
        _ = try await call("reveal", ["id": .string(own)])
        _ = try await call("reveal", [:])
        #expect(revealed == [[images.folder.appendingPathComponent("Sea.png")], [images.folder]])
        await #expect(throws: PageError.self) { try await call("remove", ["id": "file:/etc/hosts"]) }
        await #expect(throws: PageError.self) { try await call("remove", ["id": "starryNight"]) }
        // The background in use is refused natively, whatever the page shows.
        current = BackdropSelection(id: own)
        do {
            _ = try await call("remove", ["id": .string(own)])
            Issue.record("the background in use was removed")
        } catch let error as PageError {
            #expect(error.code == "cmux.settings.backdrop.in_use")
        }
        current = nil
        // Its hand placement goes with it.
        BackdropPlacementStore.shared.set(.init(centerX: 0.3, centerY: 0.5, zoom: 2), for: own)
        #expect(try await call("remove", ["id": .string(own)])["bytes"]?.doubleValue == 0)
        #expect(BackdropPlacementStore.shared.placement(for: own) == nil, "a removed picture kept its placement")
        await #expect(throws: PageError.self) { try await call("nothing", [:]) }
    }

    @Test func adjustPlacesThePictureOrSaysThereIsNone() async throws {
        var shows = false, asked = 0
        let provider = BackdropImagesPageProvider(images: BackdropUserImages(folder: FileManager.default.temporaryDirectory),
                                                  use: { _ in "" }, adjust: { asked += 1; return shows })
        do {
            _ = try await provider.call(BackdropImagesPageProvider.prefix + "adjust", params: [:], context: Self.context)
            Issue.record("adjust with no picture did not refuse")
        } catch let error as PageError {
            #expect(error.code == "cmux.settings.backdrop.not_adjustable")
        }
        shows = true
        _ = try await provider.call(BackdropImagesPageProvider.prefix + "adjust", params: [:], context: Self.context)
        #expect(asked == 2)
    }

    /// Collages through the page (backgrounds plan phase 7): save draws one and answers its id,
    /// get reads it back, delete removes it but never the background in use.
    @Test func collagesSaveReadAndDelete() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-own-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let images = BackdropUserImages(folder: folder)
        let picture = folder.appendingPathComponent("Sea.png")
        try BackdropCollagesFixture.png(to: picture)
        var current: BackdropSelection?
        let provider = BackdropImagesPageProvider(images: images, use: { _ in "" }, inUse: { current })
        let call = { (op: String, params: JSONValue) in
            try await provider.call(BackdropImagesPageProvider.prefix + op, params: params, context: Self.context)
        }
        let collage: JSONValue = ["name": "Sea", "fill": "#000000",
                                  "layers": [["source": .string("file:\(picture.path)"), "x": 0, "y": 0, "width": 1, "height": 1,
                                              "opacity": 1, "cornerRadius": 0]]]
        let id = try #require(try await call("collage.save", ["collage": collage])["id"]?.stringValue)
        #expect(try await call("collage.get", ["id": .string(id)])["name"]?.stringValue == "Sea")
        do {
            _ = try await call("collage.save", ["collage": ["name": "Bad", "fill": "#000000", "layers": [["source": "desktop"]]]])
            Issue.record("a malformed collage was saved")
        } catch let error as PageError {
            #expect(error.code == "cmux.settings.backdrop.collage.invalid")
        }
        current = .collage(id: id)
        await #expect(throws: PageError.self) { try await call("collage.delete", ["id": .string(id)]) }
        current = nil
        _ = try await call("collage.delete", ["id": .string(id)])
        await #expect(throws: PageError.self) { try await call("collage.get", ["id": .string(id)]) }
    }
}

/// A small PNG for the page tests.
enum BackdropCollagesFixture {
    static func png(to url: URL) throws {
        let context = try #require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
    }
}
