import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextBridgeUI
import CmuxNextPages
import CmuxNextSettings
import CmuxNextSidebar
import Foundation
import Testing

/// The icon picker's Image and SVG tabs (cx-qno.2.1): a session whose owner stores assets shows
/// them, the page's `asset.put` reaches that owner with the asset's media type and returns the icon
/// value it gave, and the sidebar draws a stored SVG as an image, not the placeholder symbol.
@MainActor
struct IconPickerAssetTabTests {
    static let context = PageCallContext(page: "cmux.icon-picker", userGesture: true)
    static let icon = "svg:sha256-" + String(repeating: "a", count: 64)
    static let svg = Data(##"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16"><path d="M0 0h16v16H0z" fill="#d22"></path></svg>"##.utf8)

    @Test func aSessionWithAnOwnerStoreShowsAssetTabsAndPutsThere() async throws {
        let provider = IconPickerProvider(prefs: IconPickerPrefsStore(services: nil))
        var stored: [(String, Data)] = []
        let store = IconAssetStore { mediaType, data in
            stored.append((mediaType, data))
            return Self.icon
        }
        var events: [CmuxNextSettings.JSONValue] = []
        _ = try await provider.subscribe(IconPickerProvider.sessionStream, filter: .null, context: Self.context) { events.append($0) }
        provider.begin(IconPickerSession(id: "s1", current: nil), assets: store) { _ in }
        #expect(events.last?["assets"]?.boolValue == true)

        let reply = try await provider.call("cmux.iconPicker.asset.put",
                                            params: ["kind": "svg", "base64": .string(Self.svg.base64EncodedString())], context: Self.context)
        #expect(reply["icon"]?.stringValue == Self.icon)
        #expect(stored.map(\.0) == ["image/svg+xml"])
        #expect(stored.first?.1 == Self.svg)

        // Bytes that are not the named kind never reach the owner.
        await #expect(throws: PageError.self) {
            try await provider.call("cmux.iconPicker.asset.put",
                                    params: ["kind": "image", "base64": .string(Self.svg.base64EncodedString())], context: Self.context)
        }
        #expect(stored.count == 1)

        // A session without an owner store keeps the tabs off and refuses a put.
        provider.begin(IconPickerSession(id: "s2", current: nil)) { _ in }
        #expect(events.last?["assets"]?.boolValue == false)
        await #expect(throws: PageError.self) {
            try await provider.call("cmux.iconPicker.asset.put",
                                    params: ["kind": "svg", "base64": .string(Self.svg.base64EncodedString())], context: Self.context)
        }
    }

    @Test func aWorkspaceTakesAStoredAssetIcon() {
        #expect(WorkspaceIconValue.isValid(Self.icon, assets: true))
        #expect(!WorkspaceIconValue.isValid(Self.icon), "group and tab icons take no assets")
    }

    @Test func theSidebarDrawsAStoredSVGAsAnImage() throws {
        let image = try #require(IconAssetImages.decode(Self.svg, mediaType: "image/svg+xml"), "the SVG decodes natively")
        let side = Int(IconAssetImages.side * IconAssetImages.scale)
        #expect(image.width == side && image.height == side)
        // The red square fills the icon: its center pixel is opaque red.
        let pixel = try #require(Self.pixel(image, x: side / 2, y: side / 2))
        #expect(pixel.alpha > 0.9 && pixel.red > 0.6 && pixel.green < 0.3)

        let favicon = SidebarFavicon(image)
        #expect(SidebarMapping.icon(color: nil, icon: Self.icon, asset: { $0 == Self.icon ? favicon : nil }) == .favicon(favicon))
        // While the asset loads the row keeps the placeholder symbol.
        #expect(SidebarMapping.icon(color: nil, icon: Self.icon) == .symbol("photo"))
    }

    @Test func untrustedBytesDecodeOnlyAsWhatTheyClaim() {
        // A PDF labelled as SVG never reaches NSImage's other decoders; a PNG labelled JPEG is refused.
        #expect(IconAssetImages.decode(Data("%PDF-1.4\n".utf8), mediaType: "image/svg+xml") == nil)
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        #expect(IconAssetImages.decode(png, mediaType: "image/jpeg") == nil)
        // A downloaded SVG over the owner's limit is refused before it is sent.
        var big = Self.svg
        big.append(Data(repeating: 0x20, count: IconAssetKind.maxSVGBytes))
        #expect(IconAssetKind.svg.prepare(downloaded: big) == nil)
        #expect(IconAssetKind.svg.prepare(downloaded: Self.svg)?.mediaType == "image/svg+xml")
    }

    private static func pixel(_ image: CGImage, x: Int, y: Int) -> (red: CGFloat, green: CGFloat, alpha: CGFloat)? {
        let color = NSBitmapImageRep(cgImage: image).colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
        return color.map { ($0.redComponent, $0.greenComponent, $0.alphaComponent) }
    }
}
