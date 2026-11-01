import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
@testable import CmuxNextBrowser
@testable import CmuxNextDesign
@testable import CmuxNextLayout
@testable import CmuxNextPalette
@testable import CmuxNextSidebar
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Testing

/// Leo, 2026-10-14: no dramatic shadows. The tab drag ghost cast black at 28% with a 10 pt radius,
/// a lifted tab, group chip or sidebar row a 16 pt blur, the docked column an opaque 12 pt halo.
/// Every native shadow now comes from one scale, `PopupStyle.elevation1`/`elevation2` (the web's
/// `--elevation-1`/`--elevation-2`): a tight, low-alpha drop, with the thin rim carrying the edge.
@MainActor
@Suite(.closesItsWindows)
struct SubtleElevationTests {
    private let raised = PopupStyle.elevation2
    /// The largest blur any native shadow may cast (CSS terms), and the darkest alpha.
    private static let maxBlur: CGFloat = 8
    private static let maxAlpha: CGFloat = 0.16

    @Test func theScaleIsTightAndLowAlpha() {
        #expect(PopupStyle.elevation1 == Elevation(offset: 1, blur: 2, alpha: 0.07))
        #expect(PopupStyle.elevation2 == Elevation(offset: 2, blur: 6, alpha: 0.11))
        for step in [PopupStyle.elevation1, PopupStyle.elevation2] {
            #expect(step.blur <= Self.maxBlur)
            #expect(step.alpha <= Self.maxAlpha)
            #expect(step.layerRadius == step.blur / 2)
        }
    }

    @Test func aHoverCardCastsTheRaisedStep() throws {
        let panel = HoverCardPanel()
        let host = try #require(panel.contentView as? PopupHostView)
        expectRaised(host.shadowLayer, flipped: false)
    }

    @Test func aToastCastsTheRaisedStep() throws {
        let view = CmuxToastView(toast: CmuxToast(id: "t", message: "Saved"))
        expectRaised(try #require(view.layer), flipped: false)
    }

    @Test func thePaletteCastsTheRaisedStep() throws {
        _ = NSApplication.shared
        let content = PaletteContentView(model: PaletteModel())
        let window = NSWindow(contentRect: content.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = content
        defer { window.closeAfterTest() }
        let shadow = try #require(Self.shadows(in: content).first)
        #expect(shadow.shadowBlurRadius == raised.blur)
        #expect(shadow.shadowOffset == NSSize(width: 0, height: -raised.offset))
        #expect(abs((shadow.shadowColor?.alphaComponent ?? 0) - raised.alpha) < 0.001)
    }

    @Test func aLiftedTabChipOrSidebarRowCastsTheRaisedStep() throws {
        let cell = TabCell(item: TabItem(id: TabID("t"), title: "cmux"))
        cell.isLifted = true
        #expect(cell.backgroundLayer.shadowRadius == raised.layerRadius)
        #expect(abs(cell.backgroundLayer.shadowOffset.height) == raised.offset)
        let chip = TabGroupChipCell(group: TabGroupItem(id: "g", name: "Frontend"), memberCount: 2)
        chip.isLifted = true
        #expect(chip.pill.shadowRadius == raised.layerRadius)
        #expect(abs(CGFloat(chip.pill.shadowOpacity) - raised.alpha) < 0.001)
        let lift = DragLiftView(content: NSView(), count: 2)
        lift.frame = NSRect(x: 0, y: 0, width: 220, height: 28)
        lift.setLifted(true, animated: false)
        let layer = try #require(lift.layer)
        #expect(layer.shadowRadius == raised.layerRadius)
        #expect(abs(CGFloat(layer.shadowOpacity) - raised.alpha) < 0.001)
    }

    @Test func theTabDragGhostCastsTheRaisedStep() throws {
        let ghost = TabDragGhostPanel(tabImage: nil, tabSize: CGSize(width: 160, height: 28),
                                      grabOffset: CGPoint(x: 20, y: 14), aspect: 1.6, scale: 2, onGlass: false)
        let root = try #require(ghost.panel.contentView?.layer)
        let casting = Self.layers(in: root).filter { $0.shadowOpacity > 0 }
        #expect(!casting.isEmpty)
        for layer in casting {
            #expect(layer.shadowRadius == raised.layerRadius)
            #expect(abs(CGFloat(layer.shadowOpacity) - raised.alpha) < 0.001)
        }
    }

    @Test func theOmnibarSuggestionCardCastsTheRaisedStep() {
        let top = OmnibarCardTopView(frame: NSRect(x: 0, y: 0, width: 400, height: 34)).card
        expectRaised(top, flipped: false)
    }

    /// Every native shadow surface above, and the docked column's backdrop: none blurs or darkens
    /// past the scale.
    @Test func noNativeShadowPassesTheCap() throws {
        let dock = DockBackdropView(frame: NSRect(x: 0, y: 0, width: 320, height: 480))
        dock.place(cover: dock.frame, column: dock.frame.insetBy(dx: 6, dy: 6), paneCornerRadius: 8)
        let cell = TabCell(item: TabItem(id: TabID("t"), title: "cmux"))
        cell.isLifted = true
        let ghost = TabDragGhostPanel(tabImage: nil, tabSize: CGSize(width: 160, height: 28),
                                      grabOffset: CGPoint(x: 20, y: 14), aspect: 1.6, scale: 2, onGlass: false)
        let views: [NSView] = [dock, try #require(ghost.panel.contentView),
                               CmuxToastView(toast: CmuxToast(id: "t", message: "Saved"))]
        // Each view's layer tree, and its subviews' (a layer-backed subview outside a window is
        // not yet a sublayer of its parent's layer).
        let layers = views.flatMap(Self.layers(of:)) + Self.layers(in: cell.layer)
        #expect(layers.contains { $0.shadowOpacity > 0 })
        for layer in layers where layer.shadowOpacity > 0 {
            let color = layer.shadowColor.flatMap { NSColor(cgColor: $0) }?.alphaComponent ?? 1
            #expect(layer.shadowRadius * 2 <= Self.maxBlur, "\(layer)")
            #expect(CGFloat(layer.shadowOpacity) * color <= Self.maxAlpha + 0.001, "\(layer)")
        }
    }

    private func expectRaised(_ layer: CALayer, flipped: Bool) {
        #expect(layer.shadowRadius == raised.layerRadius)
        #expect(layer.shadowOffset == raised.layerOffset(flipped: flipped))
        #expect(abs(CGFloat(layer.shadowOpacity) - raised.alpha) < 0.001)
    }

    private static func layers(of view: NSView) -> [CALayer] {
        (view.layer.map(layers(in:)) ?? []) + view.subviews.flatMap(layers(of:))
    }

    private static func layers(in root: CALayer) -> [CALayer] {
        [root] + (root.sublayers ?? []).flatMap(layers(in:))
    }

    private static func shadows(in view: NSView) -> [NSShadow] {
        (view.shadow.map { [$0] } ?? []) + view.subviews.flatMap(shadows(in:))
    }
}
