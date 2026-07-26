import AppKit
import CmuxSimulator
import Foundation
import Testing
@testable import CmuxSimulatorUI

@Suite("DeviceKit chrome geometry")
struct SimulatorDeviceChromeProfileTests {
    @MainActor
    @Test("DeviceKit artwork is decoded once per chrome profile")
    func chromeArtworkIsCached() {
        let url = URL(fileURLWithPath: "/tmp/cmux-simulator-devicekit.pdf")
        var loadCount = 0
        let expectedImage = NSImage(size: NSSize(width: 1, height: 1))
        let cache = SimulatorDeviceChromeImageCache { loadedURL in
            #expect(loadedURL == url)
            loadCount += 1
            return expectedImage
        }

        #expect(cache.image(at: url) === expectedImage)
        #expect(cache.image(at: url) === expectedImage)
        #expect(loadCount == 1)

        cache.removeAll()
        #expect(cache.image(at: url) === expectedImage)
        #expect(loadCount == 2)
    }

    @Test("Maps the exact portrait screen opening")
    func portraitScreenOpening() {
        let profile = profileFixture()

        let rect = profile.screenRect(
            in: CGRect(x: 0, y: 0, width: 460, height: 840),
            orientation: .portrait
        )

        #expect(abs(rect.minX - 20) < 0.0001)
        #expect(abs(rect.minY - 30) < 0.0001)
        #expect(abs(rect.width - 400) < 0.0001)
        #expect(abs(rect.height - 800) < 0.0001)
    }

    @Test("Rotates asymmetric chrome insets with the device")
    func landscapeScreenOpening() {
        let profile = profileFixture()

        let rect = profile.screenRect(
            in: CGRect(x: 0, y: 0, width: 840, height: 460),
            orientation: .landscapeLeft
        )

        #expect(abs(rect.minX - 10) < 0.0001)
        #expect(abs(rect.minY - 20) < 0.0001)
        #expect(abs(rect.width - 800) < 0.0001)
        #expect(abs(rect.height - 400) < 0.0001)
    }

    @Test("Scales the inner screen radius in portrait and landscape")
    func screenCornerRadiusScaling() {
        let profile = profileFixture()

        #expect(profile.screenCornerRadius == 10)
        #expect(profile.scaledScreenCornerRadius(
            in: CGRect(x: 0, y: 0, width: 920, height: 1_680),
            orientation: .portrait
        ) == 20)
        #expect(profile.scaledScreenCornerRadius(
            in: CGRect(x: 0, y: 0, width: 1_680, height: 920),
            orientation: .landscapeRight
        ) == 20)
    }

    @MainActor
    @Test("Chrome drawing leaves DeviceKit padding outside the rounded body transparent")
    func chromePaddingIsTransparent() throws {
        let profile = SimulatorDeviceChromeProfile(
            screenWidth: 100,
            screenHeight: 200,
            insets: .init(top: 20, leading: 20, bottom: 20, trailing: 20),
            devicePadding: .init(top: 10, leading: 10, bottom: 10, trailing: 10),
            cornerRadius: 30,
            screenCornerRadius: 20,
            assets: [:],
            compositeURL: nil,
            buttons: []
        )
        let bounds = CGRect(x: 0, y: 0, width: 140, height: 240)
        let view = SimulatorRemoteSurfaceView(frame: bounds)
        view.display = SimulatorDisplayMetadata(
            width: 100,
            height: 200,
            orientation: .portrait,
            scale: 1
        )
        view.chrome = profile
        view.updateChromeLayerBackground()
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 140,
            pixelsHigh: 240,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        view.draw(bounds)
        NSGraphicsContext.restoreGraphicsState()

        let paddingPixel = try #require(bitmap.colorAt(x: 2, y: 120))
        let bodyPixel = try #require(bitmap.colorAt(x: 70, y: 120))
        #expect(paddingPixel.alphaComponent == 0)
        #expect(bodyPixel.alphaComponent == 1)
    }

    @Test("DeviceKit edge artwork keeps its natural cap thickness")
    func deviceKitArtworkUsesNaturalCapGeometry() throws {
        let body = CGRect(x: 10, y: 20, width: 300, height: 500)
        let layout = SimulatorDeviceChromeAssetLayout(
            body: body,
            imageSizes: [
                "topLeft": CGSize(width: 96, height: 96),
                "top": CGSize(width: 2, height: 96),
                "topRight": CGSize(width: 96, height: 96),
                "right": CGSize(width: 96, height: 2),
                "bottomRight": CGSize(width: 96, height: 96),
                "bottom": CGSize(width: 2, height: 96),
                "bottomLeft": CGSize(width: 96, height: 96),
                "left": CGSize(width: 96, height: 2),
            ]
        )

        #expect(layout.rect(for: "topLeft") == CGRect(x: 10, y: 424, width: 96, height: 96))
        #expect(layout.rect(for: "top") == CGRect(x: 106, y: 424, width: 108, height: 96))
        #expect(layout.rect(for: "right") == CGRect(x: 214, y: 116, width: 96, height: 308))
        #expect(layout.rect(for: "bottom") == CGRect(x: 106, y: 20, width: 108, height: 96))
        #expect(layout.rect(for: "left") == CGRect(x: 10, y: 116, width: 96, height: 308))
    }

    @Test("Loads screen and bezel geometry from DeviceKit metadata")
    func metadataLoading() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let deviceRoot = root.appendingPathComponent("DeviceTypes", isDirectory: true)
        let bundle = deviceRoot.appendingPathComponent("Test Phone.simdevicetype", isDirectory: true)
        let resources = bundle.appendingPathComponent("Contents/Resources", isDirectory: true)
        let chromeRoot = root.appendingPathComponent("Chrome", isDirectory: true)
        let chromeResources = chromeRoot
            .appendingPathComponent("phone-test.devicechrome", isDirectory: true)
            .appendingPathComponent("Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: chromeResources, withIntermediateDirectories: true)

        try writePlist([
            "CFBundleIdentifier": "com.apple.CoreSimulator.SimDeviceType.Test-Phone",
        ], to: bundle.appendingPathComponent("Contents/Info.plist"))
        try writePlist([
            "chromeIdentifier": "com.apple.dt.devicekit.chrome.phone-test",
            "mainScreenWidth": 1_200,
            "mainScreenHeight": 2_400,
            "mainScreenScale": 3,
        ], to: resources.appendingPathComponent("profile.plist"))
        let pixel = try #require(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        ))
        try pixel.write(to: chromeResources.appendingPathComponent("Mystery.png"))
        try pixel.write(to: chromeResources.appendingPathComponent("Mystery Down.png"))
        let chromeJSON = """
        {
          "images": {
            "sizing": {"leftWidth": 12, "rightWidth": 13, "topHeight": 14, "bottomHeight": 15},
            "devicePadding": {"top": 9, "left": 2, "bottom": 3, "right": 10}
          },
          "paths": {"simpleOutsideBorder": {"cornerRadiusX": 30}},
          "inputs": [{
            "name": "future-device-button",
            "image": "Mystery",
            "imageDown": "Mystery Down",
            "onTop": true,
            "usagePage": 65281,
            "usage": 512,
            "anchor": "left",
            "offsets": {
              "normal": {"x": 5, "y": 6},
              "rollover": {"x": 7, "y": 9}
            }
          }, {
            "name": "volume-up", "image": "Mystery", "anchor": "top", "align": "leading",
            "offsets": {"normal": {"x": 40, "y": 8}, "rollover": {"x": 40, "y": 3}}
          }, {
            "name": "power", "image": "Mystery", "anchor": "top", "align": "trailing",
            "offsets": {"normal": {"x": -40, "y": 8}, "rollover": {"x": -40, "y": 3}}
          }, {
            "name": "home", "image": "Mystery", "anchor": "bottom", "align": "center",
            "offsets": {"normal": {"x": 0, "y": -30}, "rollover": {"x": 0, "y": -30}}
          }]
        }
        """
        try #require(chromeJSON.data(using: .utf8)).write(
            to: chromeResources.appendingPathComponent("chrome.json")
        )
        let loader = SimulatorDeviceChromeLoader(
            deviceTypeRoots: [deviceRoot],
            chromeRoots: [chromeRoot]
        )

        let profile = await loader.load(
            deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.Test-Phone"
        )

        #expect(profile?.screenWidth == 400)
        #expect(profile?.screenHeight == 800)
        #expect(profile?.insets == .init(top: 23, leading: 14, bottom: 18, trailing: 23))
        #expect(profile?.devicePadding == .init(top: 9, leading: 2, bottom: 3, trailing: 10))
        #expect(profile?.bezelInsets == .init(top: 14, leading: 12, bottom: 15, trailing: 13))
        #expect(profile?.cornerRadius == 30)
        #expect(profile?.screenCornerRadius == 16)
        let button = try #require(profile?.buttons.first)
        #expect(button.name == "future-device-button")
        #expect(button.usagePage == 65_281)
        #expect(button.usage == 512)
        #expect(button.onTop)
        #expect(button.imageDownURL?.lastPathComponent == "Mystery Down.png")
        #expect(button.normalOffset == .init(x: 5, y: 6))
        #expect(button.rolloverOffset == .init(x: 7, y: 9))
        #expect(button.rolloverTranslation == SimulatorInputDelta(x: 2, y: -3))
        let volume = try #require(profile?.buttons.first { $0.name == "volume-up" })
        let power = try #require(profile?.buttons.first { $0.name == "power" })
        let home = try #require(profile?.buttons.first { $0.name == "home" })
        #expect(volume.rect.x == 38)
        #expect(power.rect.x == 371)
        #expect(home.rect.x == 204.5)
        #expect(home.rect.y == 17)
    }

    @Test("Installed iPhone Air uses the measured DeviceKit screen opening")
    func installedPhoneAirScreenRadius() async throws {
        let profileURL = URL(fileURLWithPath:
            "/Library/Developer/CoreSimulator/Profiles/DeviceTypes/iPhone Air.simdevicetype"
        )
        guard FileManager.default.fileExists(atPath: profileURL.path) else { return }

        let profile = await SimulatorDeviceChromeLoader().load(
            deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-Air"
        )

        let radius = try #require(profile).screenCornerRadius
        #expect(abs(radius - 56) < 0.6)
    }

    @Test("Installed M5 iPad resolves compatible DeviceKit chrome artwork")
    func installedM5IPadChromeFallback() async throws {
        let profileURL = URL(fileURLWithPath:
            "/Library/Developer/CoreSimulator/Profiles/DeviceTypes/iPad Pro 13-inch (M5).simdevicetype"
        )
        guard FileManager.default.fileExists(atPath: profileURL.path) else { return }

        let profile = await SimulatorDeviceChromeLoader().load(
            deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB"
        )

        #expect(profile != nil)
        #expect(profile?.assets.isEmpty == false)
        #expect(profile?.buttons.isEmpty == false)
    }

    private func profileFixture() -> SimulatorDeviceChromeProfile {
        SimulatorDeviceChromeProfile(
            screenWidth: 400,
            screenHeight: 800,
            insets: .init(top: 10, leading: 20, bottom: 30, trailing: 40),
            devicePadding: .zero,
            cornerRadius: 30,
            screenCornerRadius: 10,
            assets: [:],
            compositeURL: nil,
            buttons: []
        )
    }

    private func writePlist(_ value: [String: Any], to url: URL) throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: value,
            format: .xml,
            options: 0
        )
        try data.write(to: url)
    }
}
