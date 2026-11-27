import AppKit
@testable import CmuxNextDesign
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

/// The Apple Wallpapers section: every macOS wallpaper is listed, `.madesktop` descriptions by
/// their thumbnail until macOS downloads the full picture, and dynamic wallpapers draw their
/// light or dark picture with the appearance.
@MainActor @Suite struct AppleWallpapersTests {
    /// A Desktop Pictures folder shaped like macOS 26's, and a downloaded-assets folder.
    struct Fixture {
        let root: URL
        var pictures: URL { root.appendingPathComponent("Desktop Pictures", isDirectory: true) }
        var assets: URL { root.appendingPathComponent("Assets", isDirectory: true) }

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("apple-wallpapers-\(UUID().uuidString)", isDirectory: true)
            let thumbnails = pictures.appendingPathComponent(".thumbnails", isDirectory: true)
            for folder in [thumbnails, pictures.appendingPathComponent("Solid Colors"),
                           pictures.appendingPathComponent(".wallpapers/Horizon"), assets.appendingPathComponent("1f.asset/AssetData")] {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            // A light and dark picture in one file, as Sonoma.heic ships.
            try AppleWallpapersTests.heic([.white, .black], apr: ["l": 0, "d": 1], to: pictures.appendingPathComponent("Sonoma.heic"))
            try AppleWallpapersTests.heic([.gray], to: thumbnails.appendingPathComponent("Sonoma.heic"))
            try AppleWallpapersTests.heic([.blue], to: pictures.appendingPathComponent("Solid Colors/Blue.heic"))
            try AppleWallpapersTests.heic([.green], to: pictures.appendingPathComponent(".wallpapers/Horizon/Horizon.heic"))
            try Data().write(to: pictures.appendingPathComponent(".wallpapers/Horizon/Horizon Landscape.mov"))
            // A dynamic description, not downloaded, with a thumbnail for each appearance.
            for (name, color) in [("Grid", NSColor.gray), ("Grid Light", .white), ("Grid Dark", .black), ("Coast", .orange)] {
                try AppleWallpapersTests.heic([color], to: thumbnails.appendingPathComponent("\(name).heic"))
            }
            try description("Grid", dynamic: true)
            // A still description macOS has downloaded.
            try description("Coast", dynamic: false)
            try AppleWallpapersTests.heic([.red], to: assets.appendingPathComponent("1f.asset/AssetData/Coast.heic"))
            try description("Broken", dynamic: false, thumbnail: "relative.heic")
            let order = try PropertyListSerialization.data(fromPropertyList: ["Coast.madesktop", "Sonoma.heic"], format: .binary, options: 0)
            try order.write(to: pictures.appendingPathComponent(".orderedPictures.plist"))
        }

        func description(_ name: String, dynamic: Bool, thumbnail: String? = nil) throws {
            let plist: [String: Any] = [
                "isDynamic": dynamic, "isSolar": false, "mobileAssetID": name, "width": 6016, "height": 6016,
                "thumbnailPath": thumbnail ?? pictures.appendingPathComponent(".thumbnails/\(name).heic").path,
            ]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: pictures.appendingPathComponent("\(name).madesktop"))
        }

        func path(_ name: String) -> String { pictures.appendingPathComponent(name).path }

        /// Whether `url` is `name` in the fixture, however the temporary folder is spelled
        /// (a folder listing says `/private/var`).
        func names(_ url: URL?, _ name: String, in folder: URL? = nil) -> Bool {
            url?.resolvingSymlinksInPath().path == (folder ?? pictures).appendingPathComponent(name).resolvingSymlinksInPath().path
        }
    }

    /// Writes a HEIC of one solid frame per color; `apr` adds the light and dark frame metadata macOS uses.
    static func heic(_ colors: [NSColor], apr: [String: Int]? = nil, to url: URL) throws {
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.heic.identifier as CFString, colors.count, nil))
        for (index, color) in colors.enumerated() {
            let context = try #require(CGContext(data: nil, width: 64, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
                                                 space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                 bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            context.setFillColor(try #require(color.usingColorSpace(.sRGB)).cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 40))
            let image = try #require(context.makeImage())
            if index == 0, let apr {
                let metadata = CGImageMetadataCreateMutable()
                let namespace = "http://ns.apple.com/namespace/1.0/" as CFString
                CGImageMetadataRegisterNamespaceForPrefix(metadata, namespace, "apple_desktop" as CFString, nil)
                let value = try PropertyListSerialization.data(fromPropertyList: apr, format: .binary, options: 0).base64EncodedString()
                let tag = try #require(CGImageMetadataTagCreate(namespace, "apple_desktop" as CFString, "apr" as CFString, .string, value as CFString))
                CGImageMetadataSetTagWithPath(metadata, nil, "apple_desktop:apr" as CFString, tag)
                CGImageDestinationAddImageAndMetadata(destination, image, metadata, nil)
            } else {
                CGImageDestinationAddImage(destination, image, nil)
            }
        }
        #expect(CGImageDestinationFinalize(destination))
    }

    /// The red channel (0...255) of the middle pixel of `image`.
    static func red(_ image: NSImage) throws -> Int {
        let cgImage = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let rep = NSBitmapImageRep(cgImage: cgImage)
        let color = try #require(rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?.usingColorSpace(.sRGB))
        return Int((color.redComponent * 255).rounded())
    }

    @Test func everyWallpaperIsListedInTheWallpaperPanesOrder() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let wallpapers = AppleWallpapers(desktopPictures: fixture.pictures).pictures(assets: AppleWallpaperAssets(folders: [fixture.assets]))
        // The ordered ones first, then by name; a live wallpaper's movie and a description with no
        // usable thumbnail are left out.
        #expect(wallpapers.map(\.title) == ["Coast", "Sonoma", "Blue", "Grid", "Horizon"])
        let byTitle = Dictionary(uniqueKeysWithValues: wallpapers.map { ($0.title, $0) })
        #expect(byTitle["Coast"]?.isDownloaded == true)
        #expect(byTitle["Grid"]?.isDownloaded == false)
        #expect(fixture.names(byTitle["Sonoma"]?.thumbnail, ".thumbnails/Sonoma.heic"))
        #expect(fixture.names(byTitle["Blue"]?.thumbnail, "Solid Colors/Blue.heic"))
    }

    @Test func aWallpaperThatIsNotDownloadedShowsItsThumbnailForTheAppearance() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let assets = AppleWallpaperAssets(folders: [fixture.assets])
        let grid = try #require(AppleWallpaper(path: fixture.path("Grid.madesktop"), assets: assets))
        #expect(grid.isDynamic)
        #expect(grid.imageURL(for: .light).lastPathComponent == "Grid Light.heic")
        #expect(grid.imageURL(for: .dark).lastPathComponent == "Grid Dark.heic")
        let coast = try #require(AppleWallpaper(path: fixture.path("Coast.madesktop"), assets: assets))
        #expect(fixture.names(coast.imageURL(for: .dark), "1f.asset/AssetData/Coast.heic", in: fixture.assets))
        // The picker lists it by its thumbnail; its id is the description, so a download later is used.
        #expect(BackdropSelection.system(path: grid.path).thumbnailURL?.lastPathComponent == "Grid.heic")
        #expect(BackdropSelection.system(path: grid.path).title == "Grid")
    }

    /// A hand-edited `system:` path with `..` resolves (it once walked up forever).
    @Test func aPathWithDotDotResolves() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let wallpaper = AppleWallpaper(path: fixture.path("Solid Colors/../Sonoma.heic"), assets: .none)
        #expect(fixture.names(wallpaper?.thumbnail, ".thumbnails/Sonoma.heic"))
        #expect(AppleWallpaper(path: "/a/../b.madesktop", assets: .none) == nil)
        #expect(BackdropSelection.system(path: "/x/Desktop Pictures/sub/../y.jpg").thumbnailURL?.path == "/x/Desktop Pictures/sub/../y.jpg")
    }

    @Test func aDynamicPictureFollowsTheAppearance() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let sonoma = BackdropSelection.system(path: fixture.path("Sonoma.heic"))
        let source = try #require(CGImageSourceCreateWithURL(URL(fileURLWithPath: fixture.path("Sonoma.heic")) as CFURL, nil))
        #expect(BackdropAppearance.light.frame(in: source) == 0)
        #expect(BackdropAppearance.dark.frame(in: source) == 1)
        #expect(sonoma.followsAppearance)
        #expect(!BackdropSelection.system(path: fixture.path("Solid Colors/Blue.heic")).followsAppearance)

        let store = BackdropImageStore(maxPixelSize: 64)
        let light = try #require(await store.image(sonoma, dark: false))
        let dark = try #require(await store.image(sonoma, dark: true))
        #expect(try Self.red(light) > 200)
        #expect(try Self.red(dark) < 50)
        #expect(store.cached(sonoma, dark: true) === dark)
    }

    @Test func aWindowRedrawsADynamicWallpaperWhenItsAppearanceChanges() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = BackdropImageStore(maxPixelSize: 64)
        let view = WindowMaterialView(frame: NSRect(x: 0, y: 0, width: 64, height: 40), images: store)
        view.appearance = NSAppearance(named: .aqua)
        var backdrop = WindowBackdrop(backgroundOpacity: 0.5, backgroundBlur: 0)
        backdrop.selection = .system(path: fixture.path("Sonoma.heic"))
        view.apply(backdrop, tint: .black)
        // The art view by name: the inactive wash sits below it (c5ccab1e907), so it is not the
        // first subview.
        let art = try #require(view.artView.layer)
        await view.artLoad?.value
        #expect(try Self.red(try #require(art.contents as? NSImage)) > 200)

        view.appearance = NSAppearance(named: .darkAqua)
        view.viewDidChangeEffectiveAppearance()
        await view.artLoad?.value
        #expect(try Self.red(try #require(art.contents as? NSImage)) < 50)
    }
}
