import AppKit
import Foundation
import Testing
@testable import GlassHost

/// The glass host's Swift half: the page's message decodes and refuses bad ones, the host makes one
/// glass per surface under the web view at its box, follows it, and removes it; each material path draws.
@Suite(.serialized)
@MainActor
struct GlassHostTests {
    private static let box: [String: Any] = [
        "id": "g1", "level": "menu", "left": 40, "top": 60, "right": 240, "bottom": 180, "radius": 12, "opacity": 0.5,
    ]

    @Test func messagesDecodeAndBadOnesAreRefused() {
        #expect(GlassSurfaceState.decode([Self.box]) == [
            GlassSurfaceState(id: "g1", level: .menu, rect: CGRect(x: 40, y: 60, width: 200, height: 120), radius: 12, opacity: 0.5),
        ])
        #expect(GlassSurfaceState.decode([]) == [])
        var level = Self.box
        level["level"] = "frosted"
        var inverted = Self.box
        inverted["right"] = 10
        var bright = Self.box
        bright["opacity"] = 2
        var huge = Self.box
        huge["left"] = 1e9
        let many = (0..<17).map { index -> [String: Any] in
            var entry = Self.box
            entry["id"] = "g\(index)"
            return entry
        }
        for bad: Any in [[level], [inverted], [bright], [huge], [Self.box, Self.box], many, "x", [["id": "g1"]]] {
            #expect(GlassSurfaceState.decode(bad) == nil)
        }
    }

    @Test func theHostSitsUnderTheWebViewAndDrawsEachSurfaceAtItsBox() throws {
        let parent = NSView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let web = NSView(frame: CGRect(x: 0, y: 40, width: 800, height: 560))
        parent.addSubview(web)
        let host = GlassHostView()
        host.place(under: web)
        #expect(host.superview === parent)
        #expect(parent.subviews.firstIndex(of: host)! + 1 == parent.subviews.firstIndex(of: web))
        #expect(host.frame == web.frame)
        #expect(host.hitTest(CGPoint(x: 50, y: 70)) == nil)

        let state = GlassSurfaceState(id: "g1", level: .popover, rect: CGRect(x: 40, y: 60, width: 200, height: 120), radius: 12, opacity: 0.5)
        host.apply([state], zoom: 1.5)
        let glass = try #require(host.surfaces["g1"])
        #expect(glass.superview === host)
        #expect(glass.frame == CGRect(x: 60, y: 90, width: 300, height: 180))
        #expect(glass.cornerRadius == 18)
        #expect(glass.alphaValue == 0.5)

        var moved = state
        moved.rect.origin.x = 100
        host.apply([moved], zoom: 1)
        #expect(host.surfaces["g1"] === glass)
        #expect(glass.frame.minX == 100)

        host.apply([])
        #expect(host.surfaces.isEmpty)
        #expect(glass.superview == nil)
    }

    @Test func anAppCanBringItsOwnMaterial() throws {
        final class Mine: NSView, GlassSurfaceView { var cornerRadius: CGFloat = 0 }
        let host = GlassHostView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        var levels: [GlassLevel] = []
        host.makeSurface = { levels.append($0); return Mine() }
        host.apply([GlassSurfaceState(id: "a", level: .chip, rect: CGRect(x: 0, y: 0, width: 40, height: 20))])
        #expect(levels == [.chip])
        #expect(host.surfaces["a"] is Mine)
    }

    @Test func everyMaterialPathDrawsAndTakesNoClicks() {
        for material in [GlassMaterialView.Material.liquidGlass, .vibrancy, .opaque] {
            let view = GlassMaterialView(level: .menu, material: material)
            view.frame = CGRect(x: 0, y: 0, width: 100, height: 60)
            view.cornerRadius = 10
            view.tintColor = .systemBlue.withAlphaComponent(0.2)
            #expect(view.material == material)
            #expect(view.layer?.cornerRadius == 10)
            #expect(view.hitTest(CGPoint(x: 10, y: 10)) == nil)
            if material == .opaque { #expect(view.subviews.isEmpty && view.layer?.backgroundColor != nil) }
            else { #expect(!view.subviews.isEmpty) }
        }
        #expect(GlassMaterialView.Material.select(liquidGlass: true, reduceTransparency: true) == .opaque)
        #expect(GlassMaterialView.Material.select(liquidGlass: false, reduceTransparency: false) == .vibrancy)
        #expect(GlassMaterialView.systemMaterial(.chip) == .toolTip)
    }
}
