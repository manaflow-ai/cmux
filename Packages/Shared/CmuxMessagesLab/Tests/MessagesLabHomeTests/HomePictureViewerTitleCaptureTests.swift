import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import MessagesLabHome

/// The picture of the viewer's top bar under the Home chat column's round compose button (the user, 2026-11-11:
/// "center it with the button"), light and dark, written to `$CMUX_CAPTURE_DIR/viewer-title-{light,dark}.png` for a
/// Before | After review. Runs only when `CMUX_CAPTURE_DIR` is set; `HomePictureViewerKeysAndWheelTests` checks the line.
@MainActor @Suite(.serialized) struct HomePictureViewerTitleCaptureTests {
    static let folder = ProcessInfo.processInfo.environment["CMUX_CAPTURE_DIR"]

    @Test(.enabled(if: folder != nil, "set CMUX_CAPTURE_DIR to write the captures"), arguments: [true, false])
    func theTitleBesideTheComposeButton(light: Bool) async throws {
        let size = CGSize(width: 520, height: 300)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        let host = NSView(frame: CGRect(origin: .zero, size: size))
        host.wantsLayer = true
        host.layer?.backgroundColor = (light ? NSColor.white : NSColor(white: 0.12, alpha: 1)).cgColor
        window.contentView = host
        let picture = try HomePictureViewerTests.image(width: 1200, height: 700, gray: light ? 0.85 : 0.3)
        let gallery = HomePictureGallery(items: [.init(source: "s0", url: URL(fileURLWithPath: "/tmp/s0.png"), title: "Scrollbar · Dark",
                                                       row: 0, column: 0)], index: 0)
        let viewer = HomePictureViewer(frame: host.bounds, gallery: gallery, load: { _ in picture })
        viewer.reduceMotion = { true }
        host.addSubview(viewer)
        // The chat column's compose button: 38 points, 12 from the left, centred 26 from the top (HomeChatColumnView).
        let side: CGFloat = 38
        let compose = NSButton(frame: CGRect(x: 12, y: size.height - 26 - side / 2, width: side, height: side))
        compose.title = ""
        compose.bezelStyle = .circular
        compose.controlSize = .large
        compose.imagePosition = .imageOnly
        compose.image = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .regular))
        host.addSubview(compose)
        await viewer.loaded()
        viewer.needsLayout = true
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let image = try #require(rep.cgImage)
        // The top band, where the title and the button sit.
        let scale = CGFloat(image.height) / size.height
        let band = try #require(image.cropping(to: CGRect(x: 0, y: 0, width: CGFloat(image.width), height: 64 * scale)))
        let out = URL(fileURLWithPath: try #require(Self.folder)).appendingPathComponent("viewer-title-\(light ? "light" : "dark").png")
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        let dest = try #require(CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, band, nil)
        #expect(CGImageDestinationFinalize(dest))
        window.close()
    }
}
