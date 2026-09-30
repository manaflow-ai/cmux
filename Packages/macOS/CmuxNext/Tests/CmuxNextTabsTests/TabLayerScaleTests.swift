import AppKit
import Testing
import CmuxNextDesign
@testable import CmuxNextTabs

/// Text and glyph layers the strip creates itself must render at the window's
/// backing scale. A 1x CATextLayer is magnified on Retina and reads blurry.
@MainActor @Suite struct TabLayerScaleTests {
    /// A window whose backing scale the test controls.
    final class ScaledWindow: NSWindow {
        var scale: CGFloat = 2
        override var backingScaleFactor: CGFloat { scale }
    }

    final class Harness {
        let window = ScaledWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 60), styleMask: [.borderless], backing: .buffered, defer: true)
        let model: TabStripModel
        let strip: TabStripView

        init() {
            let tabs = (0..<4).map { TabItem(id: TabID("t\($0)"), title: "lawrence@lawrences-Mac \($0)", isBusy: $0 == 2) }
            model = TabStripModel(
                tabs: tabs,
                groups: [TabGroupItem(id: TabGroupID("g"), name: "Group", colorToken: .grey)],
                selectedID: TabID("t0")
            )
            model.tabs[3].groupID = TabGroupID("g")
            strip = TabStripView(model: model)
            window.isReleasedWhenClosed = false
            strip.frame = NSRect(x: 0, y: 0, width: 1200, height: TabStripView.preferredHeight)
            window.contentView!.addSubview(strip)
            strip.layoutSubtreeIfNeeded()
            strip.sync(fromModel: true)
        }

        /// What AppKit does when the window moves to a screen with another
        /// scale: notify every view in the tree, then lay out.
        func changeBackingScale() {
            func notify(_ view: NSView) {
                view.viewDidChangeBackingProperties()
                view.subviews.forEach(notify)
            }
            notify(strip)
            strip.layoutSubtreeIfNeeded()
        }

        /// Layers AppKit does not manage (no view delegate) that rasterize
        /// content: text, shapes, and image layers.
        func rasterLayers() -> [CALayer] {
            var result: [CALayer] = []
            func walk(_ layer: CALayer) {
                if !(layer.delegate is NSView), layer is CATextLayer || layer is ChromeTextLayer || layer is CAShapeLayer || layer.contents != nil {
                    result.append(layer)
                }
                for sublayer in layer.sublayers ?? [] { walk(sublayer) }
            }
            func visit(_ view: NSView) {
                if let layer = view.layer { walk(layer) }
                view.subviews.forEach(visit)
            }
            visit(strip)
            return result
        }
    }

    @Test func textLayersMatchBackingScaleAndFollowChanges() throws {
        let h = Harness()
        let cell = try #require(h.strip.cells[TabID("t0")])
        #expect(cell.titleLayer.contentsScale == 2)
        #expect(h.strip.groups.chips.isEmpty == false)
        let layers = h.rasterLayers()
        #expect(layers.contains { $0 is ChromeTextLayer })
        for layer in layers { #expect(layer.contentsScale == 2, "\(type(of: layer)) at \(layer.contentsScale)x") }

        h.window.scale = 1
        h.changeBackingScale()
        #expect(cell.titleLayer.contentsScale == 1)
        for layer in h.rasterLayers() { #expect(layer.contentsScale == 1, "\(type(of: layer)) at \(layer.contentsScale)x") }

        h.window.scale = 2
        h.changeBackingScale()
        for layer in h.rasterLayers() { #expect(layer.contentsScale == 2, "\(type(of: layer)) at \(layer.contentsScale)x") }
    }

    @Test func titleFrameIsPixelAligned() throws {
        let h = Harness()
        let cell = try #require(h.strip.cells[TabID("t1")])
        let origin = cell.layer.convert(cell.titleLayer.frame.origin, to: h.strip.layer)
        #expect((origin.x * 2).rounded() == origin.x * 2)
        #expect((origin.y * 2).rounded() == origin.y * 2)
    }
}
