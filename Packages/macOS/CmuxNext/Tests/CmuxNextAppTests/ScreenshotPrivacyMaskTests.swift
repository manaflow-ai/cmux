import AppKit
@testable import CmuxNextApp
import CmuxNextActions
import Testing
import WebKit
import CmuxNextScreenshots

/// An agent's `cmux window|pane|tab screenshot` (Leo 2026-10-21: "cmux only lets a person run the
/// window screenshot action. doesnt seem right"). The app's capture cannot reproduce the browser
/// host's secret mask (vault, TOTP and typed secrets on a page), so an automation run paints every
/// area that draws web content the app does not own black before any pixel leaves the app; the
/// app's own chat and page views stay visible.
@MainActor @Suite struct ScreenshotPrivacyMaskTests {
    /// A window-sized root with `children` placed in it.
    func window(_ children: [NSView]) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        for child in children { root.addSubview(child) }
        window.contentView = root
        return window
    }

    @Test func aWebViewTheAppDoesNotOwnIsMasked() throws {
        let page = WKWebView(frame: NSRect(x: 10, y: 20, width: 100, height: 50))
        let host = NSView(frame: NSRect(x: 200, y: 100, width: 150, height: 150))
        let nested = WKWebView(frame: NSRect(x: 5, y: 5, width: 40, height: 30))
        host.addSubview(nested)
        let window = window([page, host])
        let rects = ScreenshotPrivacyMask.foreignWebContentRects(in: try #require(window.contentView))
        #expect(rects.contains(NSRect(x: 10, y: 20, width: 100, height: 50)))
        #expect(rects.contains(NSRect(x: 205, y: 105, width: 40, height: 30)))
        #expect(rects.count == 2)
    }

    @Test func theAppsOwnPageViewIsNotMasked() throws {
        let content = WKWebView(frame: .zero)
        let page = InternalPageView(key: "settings", page: .settings, content: content)
        page.frame = NSRect(x: 0, y: 0, width: 200, height: 200)
        content.frame = page.bounds
        let window = window([page])
        #expect(ScreenshotPrivacyMask.foreignWebContentRects(in: try #require(window.contentView)).isEmpty)
    }

    @Test func aHiddenWebViewDrawsNothingAndIsNotMasked() throws {
        let page = WKWebView(frame: NSRect(x: 0, y: 0, width: 50, height: 50))
        page.isHidden = true
        let window = window([page])
        #expect(ScreenshotPrivacyMask.foreignWebContentRects(in: try #require(window.contentView)).isEmpty)
    }

    /// Only a person's own run is unmasked. An app's run carries `user` during the person's gesture
    /// in it (the native provider keeps `callerApp`), and an agent names its chat or terminal: all masked.
    @Test func onlyAPersonsOwnRunIsUnmasked() {
        func invocation(_ origin: ActionOrigin) -> ActionInvocation { ActionInvocation(target: nil, arguments: [:], origin: origin) }
        #expect(!ScreenshotPrivacyMask.applies(to: invocation(.user)))
        for origin in ActionOrigin.allCases where origin != .user {
            #expect(ScreenshotPrivacyMask.applies(to: invocation(origin)), "\(origin)")
        }
        var app = invocation(.user)
        app.callerApp = "com.example.sidebar-app"
        #expect(ScreenshotPrivacyMask.applies(to: app))
        var chat = invocation(.user)
        chat.callerAgentSession = "agent-1"
        #expect(ScreenshotPrivacyMask.applies(to: chat))
        var terminal = invocation(.user)
        terminal.callerTerminal = "term_1"
        #expect(ScreenshotPrivacyMask.applies(to: terminal))
    }

    /// The mask layer is opaque: the image under it never shows through.
    @Test func aMaskPaintsItsAreaOpaqueBlack() throws {
        let window = window([])
        let base = try #require(Self.image(width: 400, height: 300, white: true))
        let masked = try #require(WindowImageLayer.composite(base: base, window: window,
                                                             layers: [.mask(NSRect(x: 0, y: 0, width: 100, height: 100))]))
        let pixels = try #require(Self.rgba(masked))
        // Bitmap rows run top-down; window y 0..100 is the bottom of the image.
        func pixel(_ x: Int, _ yFromTop: Int) -> [UInt8] {
            let offset = (yFromTop * masked.width + x) * 4
            return Array(pixels[offset..<offset + 4])
        }
        #expect(pixel(50, masked.height - 50) == [0, 0, 0, 255])
        #expect(pixel(300, 50) == [255, 255, 255, 255])
    }

    static func image(width: Int, height: Int, white: Bool) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(white ? CGColor(red: 1, green: 1, blue: 1, alpha: 1) : CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    static func rgba(_ image: CGImage) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: image.width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return bytes
    }
}
