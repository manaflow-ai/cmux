import AppKit
import CmuxNextDesign
@testable import CmuxNextPages
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import QuartzCore
import Testing
import WebKit

/// The cold-open stand-in (feature `pageStandIn`): a page shows its theme's background
/// and its title from the open's turn, the first paint takes it off in that callback's turn, and
/// neither showing, resizing, repainting nor removing it ever adds an animation (p13-webui.md 4.5).
@MainActor
struct PageStandInTests {
    private let descriptor = PageDescriptor(id: "test.stand-in", resource: "stand-in", processGroup: .solo, namespaces: [])

    /// A page view that loads nothing (its first paint comes from the test), at a pane's size.
    private func page() -> PageWebView {
        let configuration = WKWebViewConfiguration()
        let view = PageWebView(descriptor: descriptor, configuration: configuration,
                               inputReadiness: PageInputReadiness(configuration: configuration), routes: [], route: nil,
                               options: .standard, surface: nil, dynamicResources: nil, pooled: false, load: false,
                               chromium: nil, deadlines: .testing())
        view.frame = NSRect(x: 0, y: 0, width: 480, height: 320)
        view.layoutSubtreeIfNeeded()
        return view
    }

    /// The animation keys on `layer` and every layer under it.
    private func animationKeys(_ layer: CALayer) -> [String] {
        (layer.animationKeys() ?? []) + (layer.sublayers ?? []).flatMap(animationKeys)
    }

    @Test func aColdOpenShowsTheStandInInItsTurnAndTheFirstPaintTakesItOffInItsTurn() throws {
        let view = page()
        view.showStandIn(title: "Settings")
        let standIn = try #require(view.standIn)
        #expect(view.showsStandIn)
        #expect(standIn.superlayer === view.layer, "the stand-in is not on the page in the open's turn")
        #expect(standIn.zPosition > 0, "a Chromium page's view added later would cover the stand-in")
        #expect(standIn.frame == view.bounds)
        #expect(standIn.title.string == "Settings")
        #expect(standIn.title.font.pointSize == TypeScale.title * CGFloat(view.pageZoom))
        view.notePainted()
        #expect(!view.showsStandIn)
        #expect(standIn.superlayer == nil, "the stand-in outlived the first paint's turn")
    }

    @Test func aPageThatPaintedGetsNoStandIn() {
        let view = page()
        view.notePainted()
        view.showStandIn(title: "Settings")
        #expect(!view.showsStandIn)
    }

    @Test func aPreloadCoverKeepsItsFrameAndGetsNoStandInOverIt() throws {
        let view = page()
        let context = try #require(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        view.addSubview(PagePreloadCoverView(image: image, frame: view.bounds))
        view.showStandIn(title: "Settings")
        #expect(!view.showsStandIn)
    }

    @Test func theStandInPaintsThePagesBackgroundAndSecondaryText() throws {
        let view = page()
        view.showStandIn(title: "Settings")
        let standIn = try #require(view.standIn)
        let theme = view.currentTheme()
        let background = try #require(theme.variables["--cmux-surface-background"])
        let text = try #require(theme.variables["--cmux-text-secondary"])
        #expect(standIn.backgroundColor == PageStandInLayer.color(css: background))
        #expect(standIn.title.foregroundColor == PageStandInLayer.color(css: text))
    }

    @Test func showingResizingRepaintingAndRemovingAddNoAnimationEvenInAnImplicitAnimationGroup() throws {
        let view = page()
        var standIn: PageStandInLayer?
        NSAnimationContext.runAnimationGroup { context in // motion: allow the test opens the group the stand-in must ignore
            context.duration = 1
            context.allowsImplicitAnimation = true
            view.showStandIn(title: "Settings")
            standIn = view.standIn
            view.frame = NSRect(x: 0, y: 0, width: 640, height: 400)
            view.layoutSubtreeIfNeeded()
            view.standIn?.layoutIfNeeded()
            view.additionalZoom = 1.25
            view.repaintStandIn()
        }
        let shown = try #require(standIn)
        #expect(animationKeys(shown).isEmpty, "the stand-in animated: \(animationKeys(shown))")
        #expect(shown.frame == view.bounds)
        for key in ["position", "bounds", "backgroundColor", "opacity", "hidden", "onOrderIn", "onOrderOut", "sublayers"] {
            #expect(shown.action(forKey: key) == nil, "the stand-in has an action for \(key)")
        }
        NSAnimationContext.runAnimationGroup { context in // motion: allow the test opens the group the stand-in must ignore
            context.duration = 1
            context.allowsImplicitAnimation = true
            view.notePainted()
        }
        #expect(animationKeys(shown).isEmpty, "the stand-in's removal animated: \(animationKeys(shown))")
        #expect(shown.superlayer == nil)
    }

    @Test func theColorParserReadsTheThemesCSSForm() {
        #expect(PageStandInLayer.color(css: "rgba(255, 0, 51, 0.5)") == CGColor(srgbRed: 1, green: 0, blue: 0.2, alpha: 0.5))
        #expect(PageStandInLayer.color(css: "rgba(0, 0, 0, 0)") == CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0))
        #expect(PageStandInLayer.color(css: "#ffffff") == nil)
        #expect(PageStandInLayer.color(css: "rgba(1, 2, 3)") == nil)
        #expect(PageStandInLayer.color(css: "rgba(1, x, 3, 1)") == nil)
    }
}
