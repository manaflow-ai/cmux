import AppKit
@testable import CmuxNextDesign
import Testing

/// A capture backdrop (`debug.capture_backdrop`) is the app's own patterned window behind a
/// window, and a snapshot of the window composites it behind the window, so a translucent
/// window or its glass shows the pattern (ask: lifted-row glass translucency could not be shown
/// against the capture mini's uniform dark desktop, which a snapshot never includes).
@Suite struct CaptureBackdropPatternTests {
    @Test func patternsAreNamedAsTheDebugMethodTakesThem() {
        #expect(CaptureBackdropPattern(name: "checker") == .checker)
        #expect(CaptureBackdropPattern(name: "stripes") == .stripes)
        #expect(CaptureBackdropPattern(name: "image:/tmp/a.png") == .image(URL(fileURLWithPath: "/tmp/a.png")))
        #expect(CaptureBackdropPattern(name: "image:relative.png") == nil, "an image is an absolute path")
        #expect(CaptureBackdropPattern(name: "plaid") == nil)
    }

    @Test func checkerAlternatesBothWaysAndStripesOnlyAcross() {
        let cell = CaptureBackdropPattern.cell
        let origin = CGPoint(x: cell / 2, y: cell / 2)
        let right = CGPoint(x: cell * 1.5, y: cell / 2)
        let up = CGPoint(x: cell / 2, y: cell * 1.5)
        #expect(CaptureBackdropPattern.checker.isFirstColor(at: origin) != CaptureBackdropPattern.checker.isFirstColor(at: right))
        #expect(CaptureBackdropPattern.checker.isFirstColor(at: origin) != CaptureBackdropPattern.checker.isFirstColor(at: up))
        #expect(CaptureBackdropPattern.stripes.isFirstColor(at: origin) != CaptureBackdropPattern.stripes.isFirstColor(at: right))
        #expect(CaptureBackdropPattern.stripes.isFirstColor(at: origin) == CaptureBackdropPattern.stripes.isFirstColor(at: up))
    }

    @Test func theBackdropIsCompositedBehindEverythingElse() {
        #expect(NSWindow.compositeOrder(front: [40, 31, 10], backdrop: 7) == [40, 31, 10, 7])
        #expect(NSWindow.compositeOrder(front: [7, 40, 10], backdrop: 7) == [40, 10, 7], "the backdrop is never in front")
        #expect(NSWindow.compositeOrder(front: [40, 10], backdrop: nil) == [40, 10])
    }
}

@MainActor @Suite(.serialized) struct CaptureBackdropSnapshotTests {
    /// The window server composites only on-screen windows.
    @Test(.enabled("needs a display: the window server composites only on-screen windows") { !NSScreen.screens.isEmpty })
    func aTranslucentWindowsSnapshotShowsItsBackdropThroughIt() throws {
        let frame = NSRect(x: 240, y: 240, width: 256, height: 256)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.hasShadow = false
        window.backgroundColor = NSColor(white: 1, alpha: 0.4)
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        defer { window.setCaptureBackdrop(nil) }

        let bare = try #require(window.compositedSnapshotWithOverlays()?.image)
        // The window's left edge (240) is half a cell into a stripe: these are the middles of two
        // neighbouring stripes, away from their edges.
        let left = CGPoint(x: CaptureBackdropPattern.cell, y: frame.height / 2)
        let right = CGPoint(x: CaptureBackdropPattern.cell * 2, y: frame.height / 2)
        #expect(Self.pixel(bare, at: left, points: frame.size) == Self.pixel(bare, at: right, points: frame.size),
                "without a backdrop the snapshot is the window alone")

        let backdrop = try #require(window.setCaptureBackdrop(.stripes))
        #expect(window.captureBackdrop === backdrop)
        let shown = try #require(window.compositedSnapshotWithOverlays()?.image)
        let a = Self.pixel(shown, at: left, points: frame.size)
        let b = Self.pixel(shown, at: right, points: frame.size)
        #expect(a != b, "the stripes behind the translucent window show in its snapshot")
        #expect(a[3] == 255 && b[3] == 255, "the backdrop is opaque behind the window")

        window.setCaptureBackdrop(nil)
        #expect(window.captureBackdrop == nil, "none takes it away")
        #expect(!backdrop.isVisible)
    }

    /// Each window's snapshot shows its own backdrop only. A backdrop covers its window's screen, so window A's,
    /// ordered just behind A, is above window B; taken as an overlay of B (an app window above B over its frame),
    /// it covered B in B's snapshot (review of the first head).
    @Test(.enabled("needs a display: the window server composites only on-screen windows") { !NSScreen.screens.isEmpty })
    func aSnapshotShowsOnlyItsOwnWindowsBackdrop() throws {
        let size = NSSize(width: 160, height: 160)
        func translucent(at origin: NSPoint) -> NSWindow {
            let window = NSWindow(contentRect: NSRect(origin: origin, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.isOpaque = false
            window.hasShadow = false
            window.backgroundColor = NSColor(white: 1, alpha: 0.4)
            return window
        }
        let b = translucent(at: NSPoint(x: 240, y: 240))
        b.orderFrontRegardless()
        defer { b.orderOut(nil) }
        b.setCaptureBackdrop(.checker)
        defer { b.setCaptureBackdrop(nil) }
        // A in front of B and beside it: A's screen-sized backdrop, just behind A, is above B.
        let a = translucent(at: NSPoint(x: 480, y: 240))
        a.orderFrontRegardless()
        defer { a.orderOut(nil) }
        a.setCaptureBackdrop(.stripes)
        defer { a.setCaptureBackdrop(nil) }

        let center = CGPoint(x: CaptureBackdropPattern.cell, y: CaptureBackdropPattern.cell)
        let bShot = try #require(b.compositedSnapshotWithOverlays())
        #expect(bShot.floating == 0, "another window's backdrop is never an overlay")
        #expect(Self.isNeutral(Self.pixel(bShot.image, at: center, points: size)), "B shows its checker, not A's stripes")
        let aShot = try #require(a.compositedSnapshotWithOverlays()?.image)
        #expect(!Self.isNeutral(Self.pixel(aShot, at: center, points: size)), "A shows its stripes, not B's checker")
    }

    /// Grey (the checker under white) rather than a stripe's orange or blue.
    private static func isNeutral(_ rgba: [UInt8]) -> Bool {
        abs(Int(rgba[0]) - Int(rgba[2])) < 24
    }

    /// The RGBA bytes of `image` at `point` (window points from the bottom left, `points` the window's size).
    private static func pixel(_ image: CGImage, at point: CGPoint, points: CGSize) -> [UInt8] {
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        // The context's rows run top to bottom in memory; the point is from the bottom.
        let x = min(width - 1, Int(point.x * CGFloat(width) / points.width))
        let y = min(height - 1, Int((points.height - point.y) * CGFloat(height) / points.height))
        let index = (y * width + x) * 4
        return Array(bytes[index..<index + 4])
    }
}
