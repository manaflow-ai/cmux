import AppKit
@testable import CmuxNextApps
import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// The native renderer's progress bar and menu chevron against the SwiftUI controls they replaced
/// (native-controls Before|After, controls-tour-full, 2026-11-09). In a window that is not key the
/// SwiftUI bar drew its done part grey ((170, 170, 170) in light and dark); the native bar painted the
/// primary ink in every window. The SwiftUI borderless pull-down drew its chevron in its title's ink;
/// the native one painted it secondary (title 0, chevron 134 in light). Pixels are read the way a
/// capture reads them: each control's layer rendered, over white.
@MainActor @Suite(.serialized, .closesItsWindows) struct AppSceneNativeInactiveInkTests {
    private static func host() -> (NSWindow, AppSceneHostingView) {
        let model = AppSceneModel()
        model.apply([
            .create(id: "col", type: "VStack", props: ["spacing": 6]),
            .create(id: "bar", type: "ProgressView", props: ["value": 0.6]),
            .create(id: "sort", type: "Menu", props: ["title": "Sort", "menu": .array([["title": "Newest"]])]),
            .children(id: "col", children: ["bar", "sort"]),
            .root(id: "col"),
        ])
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 220, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        let hosting = AppSceneHostingView(model: model, bundleDirectory: nil)
        hosting.frame = NSRect(x: 0, y: 0, width: 220, height: 120)
        window.contentView = hosting
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        return (window, hosting)
    }

    private static func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }

    /// The darkest luminance (0 black, 1 white) in `view`'s layer, rendered over white, in the
    /// horizontal span `from`..`to` (fractions of its width).
    private static func darkest(_ view: NSView, from: CGFloat = 0, to: CGFloat = 1) -> CGFloat? {
        view.needsDisplay = true
        view.displayIfNeeded()
        guard let layer = view.layer else { return nil }
        layer.displayIfNeeded()
        let scale: CGFloat = 2
        let w = max(1, Int(ceil(view.bounds.width * scale))), h = max(1, Int(ceil(view.bounds.height * scale)))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        layer.render(in: ctx)
        guard let data = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        var best: CGFloat = 1
        for y in 0..<h {
            for x in Int(CGFloat(w) * from)..<Int(CGFloat(w) * to) {
                let p = data + (y * w + x) * 4
                let lum = (0.299 * CGFloat(p[0]) + 0.587 * CGFloat(p[1]) + 0.114 * CGFloat(p[2])) / 255
                best = min(best, lum)
            }
        }
        return best
    }

    /// Luminance of a layer color composited over `base` (both read in the same theme).
    private static func over(_ color: CGColor?, _ base: CGColor) -> CGFloat? {
        func rgba(_ c: CGColor) -> [CGFloat]? {
            guard let n = NSColor(cgColor: c)?.usingColorSpace(.sRGB) else { return nil }
            return [n.redComponent, n.greenComponent, n.blueComponent, n.alphaComponent]
        }
        guard let color, let f = rgba(color), let b = rgba(base) else { return nil }
        let mix = (0..<3).map { f[$0] * f[3] + b[$0] * (1 - f[3]) }
        return 0.299 * mix[0] + 0.587 * mix[1] + 0.114 * mix[2]
    }

    @Test func aBarInAWindowThatIsNotKeyFillsGrey() throws {
        let (window, hosting) = Self.host()
        defer { window.contentView = nil; window.close() }
        try #require(!window.isKeyWindow, "fixture: the test window is not key")
        let bar = try #require(Self.all(hosting).first { $0 is AppSceneProgressNSView })
        bar.needsDisplay = true
        bar.displayIfNeeded()
        let layers = (bar.layer?.sublayers ?? []).filter { $0.cornerRadius > 0 && $0.frame.height > 0 }.sorted { $0.frame.width < $1.frame.width }
        let done = try #require(layers.first)
        let base = Palette.sidebarBackground.cgColor, primary = try #require(Self.over(Palette.textPrimary.cgColor, base))
        let fill = try #require(Self.over(done.backgroundColor, base)), ground = try #require(Self.over(base, base))
        // AppKit's inactive bar sits about a third of the way from the ground to the ink (170 on white, 170 on dark).
        #expect(abs(fill - primary) > 0.2, "the done part paints the primary ink (\(fill), primary \(primary)) in a window that is not key")
        #expect(abs(fill - ground) > 0.15, "the done part still shows against the ground: fill \(fill), ground \(ground)")
    }

    @Test func aMenuChevronTakesItsTitleInk() throws {
        let (window, hosting) = Self.host()
        defer { window.contentView = nil; window.close() }
        let menu = try #require(Self.all(hosting).first { $0 is AppSceneMenuNSView })
        let chevron = try #require(menu.subviews.first { $0 is NSImageView })
        let title = try #require(menu.subviews.first { !($0 is NSImageView) })
        // The same glyph tinted in the title's ink, beside it: a 1x display antialiases a thin chevron
        // short of full ink, so the chevron is held to its own glyph in that ink, not to the title's stems.
        let reference = NSImageView(frame: chevron.frame)
        reference.wantsLayer = true
        reference.image = (chevron as? NSImageView)?.image
        reference.contentTintColor = Palette.textPrimary
        menu.addSubview(reference)
        menu.layoutSubtreeIfNeeded()
        let chevronInk = try #require(Self.darkest(chevron)), titleInk = try #require(Self.darkest(title))
        let referenceInk = try #require(Self.darkest(reference))
        #expect(titleInk < 0.5, "fixture: the title drew: \(titleInk)")
        #expect(referenceInk < 0.8, "fixture: the reference chevron drew: \(referenceInk)")
        #expect(abs(chevronInk - referenceInk) < 0.05, "chevron \(chevronInk), the same glyph in the title's ink \(referenceInk), title \(titleInk)")
    }
}
