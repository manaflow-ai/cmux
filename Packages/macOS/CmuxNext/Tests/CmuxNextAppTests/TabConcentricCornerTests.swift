import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextDesign
import CmuxNextSettings
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Foundation
import Testing

/// Lawrence 2026-10-29 (screenshot of a terminal tab over its pane): "i dont think both the tab
/// roundness matches the bg pane roundness". Two shapes meet the first tab there:
///
/// - The rounded card the tab strip sits in (the curved main pane; under Floating Panes, the pane's
///   own card). A shape nested in a rounded corner reads as part of it only when it is concentric:
///   its radius is the outer radius less the gap between them. The first pill sits `inset` points in
///   from the card's top and leading edges, so its radius is `card radius - inset`; it was the fixed
///   item radius (6 pt compact) inside a 10 pt card 2 pt away, so the two curves diverged.
/// - The tab's hover card, which hangs from the tab with no gap (`HoverCardPanel.targetGap`): it
///   had the floating panels' 10-12 pt radius under a 6-7 pt pill. A card attached to its tab takes
///   the tab's radius.
///
/// Every pill of the strip uses the same radius (one token, `Metrics.tabCornerRadius`), so the
/// other tabs and the strip's + button match the first one.
@MainActor @Suite(.serialized, .closesItsWindows) struct TabConcentricCornerTests {
    /// The macOS 26 titled-window corner radius (`NSWindow.frameCornerRadius` when AppKit reports none).
    static let windowCornerRadius: CGFloat = 16

    private func load(_ style: ChromeStyle?, density: Density) {
        let appearance: JSONValue = style.map { .object(["chromeStyle": .string($0.rawValue)]) } ?? .object([:])
        let snapshot = CmuxConfigSnapshot.parse(.object(["appearance": appearance]), validDensities: SettingsApplier.validDensities,
                                                validMetrics: SettingsApplier.validMetrics)
        _ = SettingsApplier(registry: ActionRegistry.standard()).apply(snapshot)
        DesignSettings.shared.density = density
    }

    private func reset() { load(nil, density: .compact) }

    /// The rounded card the strip's top-leading corner sits in, and its radius; nil when that
    /// corner is square or outlined (the pill then starts on the outline, not in a curve).
    static func enclosingCardRadius() -> CGFloat? {
        if Metrics.floatingPanes { return Metrics.paneCornerRadius > 0 ? Metrics.paneCornerRadius : nil }
        guard Metrics.mainPaneCurved, Metrics.paneBorder == .none else { return nil }
        let radius = Metrics.mainPaneCornerRadius(windowCornerRadius: windowCornerRadius)
        return radius > 0 ? radius : nil
    }

    struct Scene {
        let window: NSWindow
        let host: NSView
        let strip: TabStripView
        /// The first pill in the host (flipped: y grows down).
        let pill: CGRect
        /// The rounded card's rect in the host: the cell under Floating Panes is inset by the padding.
        let card: CGRect
        var firstCell: TabCell? { strip.cells.values.min(by: { $0.frame.minX < $1.frame.minX }) }
    }

    /// A top-row pane: its cell's top-left corner is the main pane card's (Floating Panes: the
    /// pane card is the cell inset by the padding), with the strip in it as the layout puts it.
    static func scene(tabs: Int = 3, width: CGFloat = 700) -> Scene {
        _ = NSApplication.shared
        let model = TabStripModel(tabs: (0..<tabs).map { TabItem(id: TabID("tab\($0)"), title: "lawrence@cmux-orchestrator \($0)") },
                                  selectedID: TabID("tab0"))
        let strip = TabStripView(model: model)
        strip.dragsWindowFromEmptySpace = false
        let size = CGSize(width: width, height: 120)
        let window = NSWindow(contentRect: NSRect(x: 200, y: 300, width: size.width, height: size.height), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = FlippedView(frame: NSRect(origin: .zero, size: size))
        host.wantsLayer = true
        window.contentView = host
        let padding = Metrics.panePadding
        let stripHeight = PaneChromeMetrics.current.resolvedStripHeight(scale: window.backingScaleFactor)
        strip.frame = NSRect(x: padding, y: padding, width: size.width - 2 * padding, height: stripHeight)
        host.addSubview(strip)
        host.layoutSubtreeIfNeeded()
        strip.layoutSubtreeIfNeeded()
        let firstPill = strip.firstTabPillFrame ?? .zero
        let pill = strip.convert(firstPill, to: host)
        let cell = host.bounds
        let card = Metrics.floatingPanes ? cell.insetBy(dx: padding, dy: padding) : cell
        return Scene(window: window, host: host, strip: strip, pill: pill, card: card)
    }

    nonisolated static let variants: [(ChromeStyle, Density)] = ChromeStyle.allCases.flatMap { style in Density.allCases.map { (style, $0) } }

    /// The first pill sits as far from the card's side as from its top (`PaneChromeEvenInsetTests`).
    /// Under Floating Panes its corner is concentric with the pane's own small card (the card's radius
    /// less the inset); in the curved main pane it is Helium's 8 pt (Lawrence 2026-10-31,
    /// `HeliumTabCornerTests`).
    @Test(arguments: variants)
    func theFirstTabIsConcentricWithTheCardItSitsIn(style: ChromeStyle, density: Density) throws {
        defer { reset() }
        load(style, density: density)
        guard let cardRadius = Self.enclosingCardRadius() else { return }
        let scene = Self.scene()
        defer { scene.window.close() }
        let inset = scene.pill.minY - scene.card.minY
        let leading = scene.pill.minX - scene.card.minX
        #expect(abs(inset - leading) <= 0.01, "\(style) \(density): the pill is \(leading) pt from the side, \(inset) pt from the top")
        let cell = try #require(scene.firstCell)
        let radius = cell.backgroundLayer.cornerRadius
        let concentric = Metrics.floatingPanes ? max(Metrics.space2, cardRadius - inset) : Metrics.heliumTabCornerRadius
        #expect(abs(radius - concentric) <= 0.01,
                "\(style) \(density): the tab's radius is \(radius) pt in a \(cardRadius) pt card \(inset) pt away; concentric is \(concentric) pt")
    }

    /// Every tab pill and the strip's + use the first pill's radius (one token), at every density.
    @Test(arguments: Density.allCases)
    func everyPillOfTheStripHasOneRadius(density: Density) throws {
        defer { reset() }
        load(nil, density: density)
        let scene = Self.scene()
        defer { scene.window.close() }
        let radii = Set(scene.strip.cells.values.map(\.backgroundLayer.cornerRadius))
        #expect(radii.count == 1, "\(density): tab radii \(radii)")
        #expect(radii.first == scene.strip.metrics.cornerRadius)
    }

    /// A tab's hover card hangs from the tab with no gap: its corners are the tab's.
    @Test(arguments: Density.allCases)
    func aTabsHoverCardHasItsTabsRadius(density: Density) throws {
        defer { reset() }
        load(nil, density: density)
        let scene = Self.scene()
        defer { scene.window.close() }
        let cardRadius = try Self.shownCardRadius(scene)
        let tabRadius = try #require(scene.firstCell).backgroundLayer.cornerRadius
        #expect(abs(cardRadius - tabRadius) <= 0.01, "\(density): the card's radius is \(cardRadius) pt under a \(tabRadius) pt tab")
    }

    /// Shows the first tab's card through the app's path (the strip's source, the coordinator, the
    /// one panel) and returns the radius the card is drawn with.
    static func shownCardRadius(_ scene: Scene) throws -> CGFloat {
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        scene.window.orderFrontRegardless()
        let cards = scene.strip.hoverCard.coordinator
        cards.appIsActive = { true }
        let id = TabID("tab0")
        cards.pin(HoverTarget(id: TabHoverCardController.targetID(id), window: scene.window.windowNumber, delay: .zero),
                  from: scene.strip.hoverCard)
        defer { cards.dismiss(.action) }
        let panel = try #require(cards.panel, "the tab's card did not show")
        defer { panel.orderOut(nil) }
        return try #require(panel.host).cornerRadius
    }

    /// The first tab in its card's corner and the card hanging from it, 2x, both densities: the
    /// contact sheet a fleet run returns
    /// (`--artifact Packages/macOS/CmuxNext/.build/tab-concentric-corners.png`).
    @Test func theCornerRendersToTheContactSheet() throws {
        defer { reset() }
        var shots: [(String, CGImage)] = []
        for density in [Density.compact, .comfortable] {
            // No `appearance.chromeStyle` (flat with the sidebar line, no rounded card: tabs keep the
            // item radius and the hover card takes it), the curved main pane, and Floating Panes.
            for style in [ChromeStyle?.none, .card, .floating] {
                load(style, density: density)
                let scene = Self.scene(tabs: 2, width: 360)
                defer { scene.window.close() }
                let image = try Self.render(scene, hoverRadius: try Self.shownCardRadius(scene))
                shots.append(("\(style?.rawValue ?? "unset (flat-sidebar-line)") \(density)", image))
            }
        }
        let sheet = PaneMoreShotsTests.contactSheet(shots)
        let out = PaneMoreShotsTests.packageRoot.appending(path: ".build/tab-concentric-corners.png")
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #require(NSBitmapImageRep(cgImage: sheet).representation(using: .png, properties: [:])).write(to: out)
        print("tab-concentric-corners: wrote \(out.path)")
    }

    /// The scene drawn over the window chrome's shade: the card, its strip, and a stand-in for the
    /// first tab's hover card (the real one is a glass window) with the radius the card uses.
    static func render(_ scene: Scene, hoverRadius radius: CGFloat) throws -> CGImage {
        let root = scene.host
        let shade = CALayer()
        shade.frame = root.bounds
        shade.backgroundColor = NSColor(white: 0.08, alpha: 1).cgColor
        let card = CALayer()
        card.frame = scene.card
        card.cornerRadius = enclosingCardRadius() ?? 0
        card.cornerCurve = .circular
        card.backgroundColor = NSColor(white: 0.16, alpha: 1).cgColor
        root.layer?.insertSublayer(shade, at: 0)
        root.layer?.insertSublayer(card, above: shade)
        let hover = CALayer()
        hover.frame = CGRect(x: scene.pill.minX, y: scene.strip.frame.maxY, width: 220, height: 50)
        hover.cornerRadius = radius
        hover.cornerCurve = .continuous
        hover.backgroundColor = NSColor(white: 0.30, alpha: 1).cgColor
        hover.borderColor = NSColor(white: 1, alpha: 0.25).cgColor
        hover.borderWidth = 0.5
        root.layer?.addSublayer(hover)
        scene.window.orderFrontRegardless()
        root.layoutSubtreeIfNeeded()
        root.displayIfNeeded()
        CATransaction.flush()
        return try upright(root)
    }

    /// The flipped host's layer tree drawn top side up (`PaneMoreShotsTests.snapshot` expects an
    /// unflipped root), at 2x.
    static func upright(_ view: NSView) throws -> CGImage {
        let scale: CGFloat = 2
        let size = view.bounds.size
        let context = try #require(CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                             bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.translateBy(x: 0, y: size.height * scale)
        context.scaleBy(x: scale, y: -scale)
        try #require(view.layer).render(in: context)
        return try #require(context.makeImage())
    }
}

/// A host with a top-left origin, as the layout's pane views are.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
