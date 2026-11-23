import AppKit
@testable import CmuxNextDesign
import CmuxNextDesignTokens
import CmuxNextTestSupport
import ObjectiveC
import Testing

/// Leo, 2026-10-25: "also when i go out of focus of the cmux-next app i still see it turn more frosted
/// like it frosts the glass before the background". ``InactiveWindowTintTests`` proves the parts (the
/// backdrop glass keeps its key look, no wash by default); this proves the picture. A real window with
/// the window backdrop (``WindowMaterialView`` with the app's ``ActiveLookScope``, edge to edge) over
/// a striped picture is captured by the window server while key, while another window of the app is
/// key, and while the app is not active, and every capture must match the key one pixel for pixel.
/// The control, the same backdrop with no scope (the glass following the key state, as before the
/// fix), must differ once the window is not key: it shows the capture can see the frost at all.
///
/// Set `CMUX_GLASS_UNFOCUSED_OUT` to a folder to keep the captures (`scripts/measure/glass-unfocused.sh`
/// runs this suite alone on a GUI Mac and packs them as the before/after shots).
@MainActor @Suite(.closesItsWindows, .serialized, .timeLimit(.minutes(2))) struct UnfocusedWindowPixelsTests {
    /// The app's one scope for this process. The scope's hook is process-wide and owned by the first
    /// scope that installs it (``ActiveLookScope/install()``), so this suite measures only when its
    /// scope is that first one (run it alone: the measure script does).
    static let scope = ActiveLookScope()
    static let ownsTheHook: Bool = {
        let marker = NSSelectorFromString("cmux_activeLookScopeInstalled") // crash-allow: our own marker selector, only looked up
        guard class_getInstanceMethod(NSWindow.self, marker) == nil else { return false }
        scope.install()
        return true
    }()

    static let size = CGSize(width: 480, height: 320)

    /// Worst-channel error between two captures: the mean and the 99th percentile, 0...255.
    struct Difference: CustomStringConvertible {
        let mean: Double
        let p99: Int
        let max: Int
        var description: String { String(format: "mean %.2f p99 %d max %d", mean, p99, max) }
        var isIdentical: Bool { mean <= 1 && p99 <= 3 }
    }

    static func rgba(_ image: CGImage, width: Int, height: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return bytes
    }

    /// Compares `a` and `b` over the window less a `rim`-pixel band at every edge (the window's own
    /// outline and shadow, which AppKit draws a shade lighter in a window that is not key).
    static func difference(_ a: CGImage, _ b: CGImage, rim: Int) -> Difference {
        let width = min(a.width, b.width), height = min(a.height, b.height)
        let pa = rgba(a, width: width, height: height), pb = rgba(b, width: width, height: height)
        var histogram = [Int](repeating: 0, count: 256)
        var total = 0, count = 0, worstSeen = 0
        for y in rim..<(height - rim) {
            for x in rim..<(width - rim) {
                let i = (y * width + x) * 4
                var worst = 0
                for c in 0..<3 { worst = Swift.max(worst, abs(Int(pa[i + c]) - Int(pb[i + c]))) }
                histogram[worst] += 1
                total += worst
                count += 1
                worstSeen = Swift.max(worstSeen, worst)
            }
        }
        var seen = 0, p99 = 0
        for (value, n) in histogram.enumerated() {
            seen += n
            if Double(seen) >= Double(count) * 0.99 { p99 = value; break }
        }
        return Difference(mean: count == 0 ? 0 : Double(total) / Double(count), p99: p99, max: worstSeen)
    }

    /// A picture with hard stripes in four colors: Liquid Glass lenses and frosts what is under it,
    /// so a frost shows as softened stripe edges and a lighter, flatter color.
    static func stripes() -> NSImage {
        NSImage(size: CGSize(width: 960, height: 640), flipped: false) { rect in
            let colors: [NSColor] = [.systemRed, .systemBlue, .systemYellow, .black]
            let band: CGFloat = 40
            var x: CGFloat = 0, i = 0
            while x < rect.width {
                colors[i % colors.count].setFill()
                NSBezierPath(rect: CGRect(x: x, y: 0, width: band, height: rect.height)).fill()
                x += band
                i += 1
            }
            return true
        }
    }

    struct Fixture {
        let window: NSWindow
        let other: NSWindow
        let backdrop: WindowMaterialView
        func close() {
            other.close()
            window.close()
        }
    }

    /// The window as the app shapes a backdrop window: titled, full-size content, see-through, the
    /// backdrop its content view and the glass running past its edges. The traffic lights are hidden:
    /// they change color with the key state by design. `other` is a second window of the app, beside
    /// it, that takes the keys.
    static func fixture(material: WindowMaterial, activeLook: ActiveLookScope?) -> Fixture {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        let frame = CGRect(origin: CGPoint(x: 120, y: 160), size: size)
        let window = NSWindow(contentRect: frame, styleMask: [.titled, .fullSizeContentView, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isOpaque = false
        window.backgroundColor = NSColor.white.withAlphaComponent(0.001)
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = true
        }
        let backdrop = WindowMaterialView(frame: CGRect(origin: .zero, size: size), images: .shared,
                                          activeLook: activeLook, fillsWindow: true)
        backdrop.autoresizingMask = [.width, .height]
        window.contentView = backdrop
        let blur = material == .glass(.clear) ? -2 : material == .frosted ? 20 : -1
        backdrop.apply(WindowBackdrop(backgroundOpacity: 0.55, backgroundBlur: blur), tint: .black)
        backdrop.showArt(stripes())
        let other = NSWindow(contentRect: CGRect(x: frame.maxX + 40, y: frame.minY, width: 160, height: 120),
                             styleMask: [.titled], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        other.backgroundColor = .gray
        return Fixture(window: window, other: other, backdrop: backdrop)
    }

    /// Waits up to `seconds` for `condition`, spinning the run loop so AppKit delivers key changes.
    static func wait(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .milliseconds(Int(seconds * 1000))
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(30))
        }
        return condition()
    }

    /// The window as composited once it stops changing: Liquid Glass eases between its key and
    /// inactive looks, so two captures 150 ms apart must agree first (bounded at 3 s).
    static func settledCapture(_ window: NSWindow) async throws -> CGImage {
        var last: CGImage?
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            CATransaction.flush()
            try await Task.sleep(for: .milliseconds(150))
            let image = try await window.screenshotImage { _ in false }
            if let last, difference(last, image, rim: 0).max <= 2 { return image }
            last = image
        }
        return try await window.screenshotImage { _ in false }
    }

    static func save(_ image: CGImage, _ name: String) async {
        guard let dir = ProcessInfo.processInfo.environment["CMUX_GLASS_UNFOCUSED_OUT"], !dir.isEmpty else { return }
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try? await NSWindow.encodeSnapshotPNG(image, to: url.appendingPathComponent("\(name).png"))
    }

    /// The captures of one fixture: key, another app window key, and (when macOS lets this process
    /// give activation away) the app not active.
    struct Captures {
        var key: CGImage
        var otherWindowKey: CGImage
        var appInactive: CGImage?
    }

    static func capture(_ fixture: Fixture, name: String) async throws -> Captures {
        NSApp.activate(ignoringOtherApps: true)
        fixture.window.makeKeyAndOrderFront(nil)
        try #require(await wait(3) { fixture.window.isKeyWindow }, "\(name): the window never became key (is the app active? \(NSApp.isActive))")
        let key = try await settledCapture(fixture.window)
        await save(key, "\(name)-key")

        fixture.other.makeKeyAndOrderFront(nil)
        try #require(await wait(3) { !fixture.window.isKeyWindow && !fixture.window.isMainWindow },
                     "\(name): the window kept the keys")
        let otherKey = try await settledCapture(fixture.window)
        await save(otherKey, "\(name)-other-window-key")

        fixture.window.makeKeyAndOrderFront(nil)
        _ = await wait(3) { fixture.window.isKeyWindow }
        NSApp.deactivate()
        var inactive: CGImage?
        if await wait(3, { !NSApp.isActive }) {
            let image = try await settledCapture(fixture.window)
            await save(image, "\(name)-app-inactive")
            inactive = image
        }
        return Captures(key: key, otherWindowKey: otherKey, appInactive: inactive)
    }

    static func gate() async -> Bool {
        await WindowScreenshotTests.hostShowsWindows() && ownsTheHook
    }

    /// The fix: glass and the picture under it look the same in a window that is not key, whether
    /// another window of the app or another app has the keys.
    @Test(.enabled("this host puts windows on screen, and this suite's scope owns the hook") { await UnfocusedWindowPixelsTests.gate() },
          arguments: [WindowMaterial.glass(.regular), .glass(.clear), .frosted])
    func theUnfocusedWindowLooksLikeTheFocusedOne(material: WindowMaterial) async throws {
        let fixture = Self.fixture(material: material, activeLook: Self.scope)
        defer { fixture.close() }
        let name = "after-\(material)".replacingOccurrences(of: "(", with: "-").replacingOccurrences(of: ")", with: "")
        let shots = try await Self.capture(fixture, name: name)
        let otherKey = Self.difference(shots.key, shots.otherWindowKey, rim: 8)
        print("GLASS_UNFOCUSED \(name) other-window-key \(otherKey)")
        #expect(otherKey.isIdentical, "\(material): another window holding the keys changed the backdrop (\(otherKey))")
        if let inactive = shots.appInactive {
            let appInactive = Self.difference(shots.key, inactive, rim: 8)
            print("GLASS_UNFOCUSED \(name) app-inactive \(appInactive)")
            #expect(appInactive.isIdentical, "\(material): the app losing focus changed the backdrop (\(appInactive))")
        } else {
            print("GLASS_UNFOCUSED \(name) app-inactive not measured: macOS kept this process active")
        }
    }

    /// The control: the same Liquid Glass backdrop with no scope follows the key state, as the
    /// window's backdrop did before ``ActiveLookGlassEffectView``, and the capture sees its frost.
    @Test(.enabled("this host puts windows on screen, and this suite's scope owns the hook") { await UnfocusedWindowPixelsTests.gate() })
    func withoutTheScopeTheGlassFrostsWhenUnfocused() async throws {
        guard #available(macOS 26.0, *), Glass.isLiquidGlassAvailable else { return }
        let fixture = Self.fixture(material: .glass(.regular), activeLook: nil)
        defer { fixture.close() }
        let shots = try await Self.capture(fixture, name: "before-glass-regular")
        let otherKey = Self.difference(shots.key, shots.otherWindowKey, rim: 8)
        print("GLASS_UNFOCUSED before-glass-regular other-window-key \(otherKey)")
        #expect(!otherKey.isIdentical, "the glass with no scope should frost when not key; the capture saw nothing (\(otherKey))")
    }
}
