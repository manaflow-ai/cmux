import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextDesignTokens
@testable import CmuxNextSidebar
import Testing

/// Lucas 2026-11-10: "for the density make sure that they are all relatively proportional in terms of
/// positioning and spacing throughout all the different modes". In a real window at each density the top
/// row (traffic lights, sidebar toggle, Back, Forward, the sidebar's +) keeps one rhythm:
/// - the lights sit as far from the window's left edge as from its top edge;
/// - every top-row button has one size, the +'s;
/// - as in cmux classic (Lawrence 2026-11-11: the gaps between the lights, the toggle and Back were uneven at
///   Compact), the lights, the toggle's glyph, Back's and Forward's stand evenly apart.
@MainActor @Suite(.serialized) struct TopRowSpacingDensityTests {
    /// The glyph's drawn extent (alpha > 0.3) in window x, from the button's image centered in its frame.
    private func ink(_ button: NSButton) throws -> ClosedRange<CGFloat> {
        let image = try #require(button.image), size = image.size, s: CGFloat = 4
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * s), pixelsHigh: Int(size.height * s),
                                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: CGRect(x: 0, y: 0, width: size.width * s, height: size.height * s))
        NSGraphicsContext.restoreGraphicsState()
        var minX = Int.max, maxX = -1
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.3 {
                minX = min(minX, x)
                maxX = max(maxX, x)
            }
        }
        let frame = button.convert(button.bounds, to: nil), origin = frame.midX - size.width / 2
        return (origin + CGFloat(minX) / s)...(origin + CGFloat(maxX + 1) / s)
    }

    @Test(arguments: DensityPreset.allCases)
    func theTopRowKeepsOneRhythm(density: DensityPreset) throws {
        _ = NSApplication.shared
        let design = DesignSettings.shared
        let saved = (design.densityTokens, design.titlebar, design.tabBarPosition)
        defer { (design.densityTokens, design.titlebar, design.tabBarPosition) = saved }
        design.densityTokens = density.tokens
        design.titlebar = .minimal
        design.tabBarPosition = .top
        let container = SidebarContainerView(model: SidebarModel())
        let root = WindowRootView(sidebar: container)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.contentView = root
        defer { window.close() }
        for _ in 0..<2 {
            root.needsLayout = true
            root.layoutSubtreeIfNeeded()
        }
        let lights = try #require(WindowTitlebar.trafficLightsFrame(in: window))
        let top = window.frame.height - lights.maxY, left = lights.minX
        let band = root.toolbarBand, plus = container.sidebarView.newButton
        let toggle = try ink(band.sidebarToggle), back = try ink(band.backButton), forward = try ink(band.forwardButton)
        let afterLights = toggle.lowerBound - lights.maxX
        let group = back.lowerBound - toggle.upperBound, pair = forward.lowerBound - back.upperBound
        print("SPACING|\(density.rawValue)|top \(top) left \(left)|after lights \(afterLights)|group \(group)|pair \(pair)")
        #expect(abs(left - top) <= 0.5, "\(density): the lights are \(left) from the left edge, \(top) from the top")
        #expect(abs(afterLights - group) <= 1.5, "\(density): the toggle's glyph is \(afterLights) right of the lights, \(group) before Back")
        for button in [band.sidebarToggle, band.backButton, band.forwardButton] as [NSView] {
            #expect(button.frame.size == plus.frame.size, "\(density): a band button is \(button.frame.size), the + is \(plus.frame.size)")
        }
        #expect(abs(pair - group) <= 1.5, "\(density): Back and Forward are \(pair) apart, the toggle and Back \(group)")
    }
}
