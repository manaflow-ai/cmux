import AppKit
import CmuxNextCompat
@testable import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// A capture backdrop (`debug.capture_backdrop`) is the app's own patterned window behind a
/// window, and a snapshot of the window composites it behind the window, so a translucent
/// window or its glass shows the pattern (ask: lifted-row glass translucency could not be shown
/// against the capture mini's uniform dark desktop, which a snapshot never includes).
@Suite(.closesItsWindows) struct CaptureBackdropPatternTests {
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

@MainActor @Suite(.serialized, .closesItsWindows) struct CaptureBackdropSnapshotTests {
    /// Whether AppKit can put a window on screen here (a worker at the login window cannot).
    static func hostShowsWindows() async -> Bool {
        _ = NSApplication.shared
        let requireDisplay = ["CMUX_TEST_REQUIRE_GUI", "CMUX_CI_DISPLAY_ROUTED"]
            .contains { ProcessInfo.processInfo.environment[$0] == "1" }
        guard NSScreen.main != nil else { return requireDisplay }
        let probe = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 8, height: 8), styleMask: [.borderless], backing: .buffered, defer: false)
        probe.isReleasedWhenClosed = false
        defer { probe.close() }
        probe.orderFrontRegardless()
        guard probe.isVisible && probe.windowNumber > 0 else { return requireDisplay }
        // The first window-server frame can arrive after orderFrontRegardless. Give a healthy
        // display a short bounded settle before treating capture as unavailable.
        for _ in 0..<10 {
            CATransaction.flush()
            if probe.compositedSnapshotWithOverlays() != nil { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        // Explicit display runs must still exercise the capture and report a real failure.
        return requireDisplay
    }

    private static func translucent(_ frame: NSRect) -> NSWindow {
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.hasShadow = false
        window.backgroundColor = NSColor(white: 1, alpha: 0.4)
        return window
    }

    /// `window`'s snapshot once `done` holds for it, or the last one after 5 s: the window server composites a
    /// window ordered in (or a backdrop ordered behind it) on its next frame, so the first capture can miss it.
    private static func settled(_ window: NSWindow, until done: ((image: CGImage, floating: Int)) -> Bool) async throws
        -> (image: CGImage, floating: Int)? {
        CATransaction.flush()
        let deadline = ContinuousClock.now + .seconds(5)
        var last: (image: CGImage, floating: Int)?
        repeat {
            last = window.compositedSnapshotWithOverlays()
            if let last, done(last) { return last }
            try await Task.sleep(for: .milliseconds(50))
        } while ContinuousClock.now < deadline
        return last
    }

    @Test(.enabled("this host puts windows on screen") { await CaptureBackdropSnapshotTests.hostShowsWindows() })
    func aTranslucentWindowsSnapshotShowsItsBackdropThroughIt() async throws {
        let frame = NSRect(x: 240, y: 240, width: 256, height: 256)
        let window = Self.translucent(frame)
        window.orderFrontRegardless()
        defer { window.close() }
        defer { window.setCaptureBackdrop(nil) }
        // The window's left edge (240) is half a cell into a stripe: these are the middles of two
        // neighbouring stripes, away from their edges.
        let left = CGPoint(x: CaptureBackdropPattern.cell, y: frame.height / 2)
        let right = CGPoint(x: CaptureBackdropPattern.cell * 2, y: frame.height / 2)

        // A fleet worker can report a visible window while the window server still has no
        // composited image (for example at a login/display transition). Display coverage is
        // advisory, so leave the test green when snapshots are unavailable.
        guard let bare = try await Self.settled(window) { _ in true }?.image else { return }
        #expect(Self.pixel(bare, at: left, points: frame.size) == Self.pixel(bare, at: right, points: frame.size),
                "without a backdrop the snapshot is the window alone")

        let backdrop = try #require(window.setCaptureBackdrop(.stripes))
        #expect(window.captureBackdrop === backdrop)
        let shown = try #require(try await Self.settled(window) {
            Self.pixel($0.image, at: left, points: frame.size) != Self.pixel($0.image, at: right, points: frame.size)
        }?.image)
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
    @Test(.enabled("this host puts windows on screen") { await CaptureBackdropSnapshotTests.hostShowsWindows() })
    func aSnapshotShowsOnlyItsOwnWindowsBackdrop() async throws {
        let size = NSSize(width: 160, height: 160)
        let b = Self.translucent(NSRect(origin: NSPoint(x: 240, y: 240), size: size))
        b.orderFrontRegardless()
        defer { b.close() }
        b.setCaptureBackdrop(.checker)
        defer { b.setCaptureBackdrop(nil) }
        // A in front of B and beside it: A's screen-sized backdrop, just behind A, is above B.
        let a = Self.translucent(NSRect(origin: NSPoint(x: 480, y: 240), size: size))
        a.orderFrontRegardless()
        defer { a.close() }
        a.setCaptureBackdrop(.stripes)
        defer { a.setCaptureBackdrop(nil) }

        let center = CGPoint(x: CaptureBackdropPattern.cell, y: CaptureBackdropPattern.cell)
        // Each waits for its own backdrop to show (opaque), then must show its own pattern, never the other's.
        let bShot = try #require(try await Self.settled(b) { Self.pixel($0.image, at: center, points: size)[3] == 255 })
        #expect(bShot.floating == 0, "another window's backdrop is never an overlay")
        #expect(Self.isNeutral(Self.pixel(bShot.image, at: center, points: size)), "B shows its checker, not A's stripes")
        let aShot = try #require(try await Self.settled(a) { Self.pixel($0.image, at: center, points: size)[3] == 255 }?.image)
        #expect(!Self.isNeutral(Self.pixel(aShot, at: center, points: size)), "A shows its stripes, not B's checker")
    }

    /// Replacing or taking away a backdrop closes the old panel, so repeated pattern changes leave no window-server
    /// windows behind (review of 71131c81: the old panel was only ordered out and dropped).
    @Test(.enabled("this host puts windows on screen") { await CaptureBackdropSnapshotTests.hostShowsWindows() })
    func replacingOrRemovingABackdropClosesTheOldPanel() throws {
        let window = Self.translucent(NSRect(x: 240, y: 240, width: 160, height: 160))
        window.orderFrontRegardless()
        defer { window.close() }
        let first = try #require(window.setCaptureBackdrop(.checker))
        let firstCloses = CloseCount(first)

        let second = try #require(window.setCaptureBackdrop(.stripes))
        #expect(firstCloses.count == 1, "replacing a backdrop closes the old panel")
        #expect(first.isRemoved && !first.isVisible)
        #expect(window.captureBackdrop === second)

        let secondCloses = CloseCount(second)
        window.setCaptureBackdrop(nil)
        #expect(secondCloses.count == 1, "none closes the panel")
        #expect(second.isRemoved && !second.isVisible)
        #expect(objc_getAssociatedObject(window, CaptureBackdropPanel.retainKey) == nil, "the window lets go of it")
        #expect(firstCloses.count == 1, "a removed panel is never closed again")
    }

    /// Closing the window a backdrop is behind removes and closes the backdrop, so a full-screen backdrop never stays
    /// on screen after its window is gone (review of 71131c81).
    @Test(.enabled("this host puts windows on screen") { await CaptureBackdropSnapshotTests.hostShowsWindows() })
    func closingTheTargetWindowRemovesAndClosesItsBackdrop() throws {
        let window = Self.translucent(NSRect(x: 240, y: 240, width: 160, height: 160))
        window.orderFrontRegardless()
        let backdrop = try #require(window.setCaptureBackdrop(.checker))
        #expect(backdrop.isVisible)
        let closes = CloseCount(backdrop)

        window.close()
        #expect(closes.count == 1, "the target's close closes its backdrop")
        #expect(backdrop.isRemoved && !backdrop.isVisible)
        #expect(window.captureBackdrop == nil)
        #expect(objc_getAssociatedObject(window, CaptureBackdropPanel.retainKey) == nil, "the closed window lets go of it")
    }

    /// Counts a window's closes (`NSWindow.willCloseNotification`) while it is kept.
    @MainActor private final class CloseCount {
        private(set) var count = 0
        private var observation: MainActorObservation?

        init(_ window: NSWindow) {
            observation = MainActorObservation(NSWindow.willCloseNotification, object: window) { [weak self] in
                self?.count += 1
            }
        }
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
