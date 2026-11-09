import AppKit
import CmuxNextDesign
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Foundation
import Testing

/// The divider drag glow gallery (Leo, 2026-11-07: "keep the line itself's glow, but don't make it glow like it's an
/// actual light bulb"): a real split handle mid-drag between two panes, light and dark, in four looks. `before` is the
/// band with its 3 pt halo; `a-core-2pt` (shipped) lights a 2 pt line and nothing past it; `b-core-1pt` lights only
/// the resting line's width; `c-core-3pt` a wider line. Written as PNGs under `divider-glow-gallery/` and bundled to
/// `divider-glow-gallery.tar` for `cmux-ci run --artifact`. Runs only with `CMUX_TEST_REQUIRE_GUI=1`.
@MainActor @Suite(.serialized, .closesItsWindows) struct AADividerGlowGalleryTests {
    enum Look: String, CaseIterable {
        case before
        case aCore2pt = "a-core-2pt"
        case bCore1pt = "b-core-1pt"
        case cCore3pt = "c-core-3pt"
    }

    static func render(_ look: Look, dark: Bool) throws -> CGImage {
        _ = NSApplication.shared
        let width: CGFloat = 240, height: CGFloat = 160
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: width, height: height), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        defer { window.closeAfterTest() }
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        root.wantsLayer = true
        root.appearance = window.appearance
        root.layer?.backgroundColor = root.performWithTheme { Palette.windowBackground.withAlphaComponent(1) }.cgColor
        window.contentView = root
        // Text-like rows on both sides, so a halo shows where it covers them.
        for side in [CGFloat(12), width / 2 + 12] {
            for row in 0..<8 {
                let bar = CALayer()
                bar.frame = CGRect(x: side, y: 14 + CGFloat(row) * 17, width: width / 2 - 24, height: 7)
                bar.cornerRadius = 3
                bar.backgroundColor = root.performWithTheme { Palette.separator.withAlphaComponent(0.9) }.cgColor
                root.layer?.addSublayer(bar)
            }
        }
        let handle = DividerHandleView(kind: .split(SplitID("gallery")), axis: .horizontal)
        handle.frame = CGRect(x: width / 2 - 4, y: 0, width: 8, height: height)
        root.addSubview(handle)
        window.orderFrontRegardless()
        handle.layoutSubtreeIfNeeded()
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: width / 2, y: 80), modifierFlags: [],
                                                   timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                   clickCount: 1, pressure: 1))
        handle.mouseDown(with: down)
        handle.glow.layer.removeAllAnimations()
        handle.glow.layer.opacity = 1
        let core = try #require(handle.glow.layer.sublayers?.first)
        let band = handle.glow.layer.frame
        func widen(_ t: CGFloat) {
            handle.glow.layer.frame = CGRect(x: band.midX - t / 2, y: band.minY, width: t, height: band.height)
            core.frame = handle.glow.layer.bounds
            core.cornerRadius = t / 2
        }
        switch look {
        case .before:
            core.shadowColor = core.backgroundColor
            core.shadowOffset = .zero
            core.shadowRadius = 3
            core.shadowOpacity = 0.9
        case .aCore2pt: break
        case .bCore1pt: widen(handle.lineThickness)
        case .cCore3pt: widen(3)
        }
        CATransaction.flush()
        root.layoutSubtreeIfNeeded()
        root.display()
        let rep = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: rep)
        handle.cancelOperation(nil)
        return try #require(rep.cgImage)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderGallery() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let out = root.appending(path: "divider-glow-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for look in Look.allCases {
            for (mode, dark) in [("light", false), ("dark", true)] {
                let image = try Self.render(look, dark: dark)
                let url = out.appending(path: "\(look.rawValue)-\(mode).png")
                let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
                CGImageDestinationAddImage(dest, image, nil)
                #expect(CGImageDestinationFinalize(dest))
            }
        }
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = root
        tar.arguments = ["cf", "divider-glow-gallery.tar", "divider-glow-gallery"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
    }
}
