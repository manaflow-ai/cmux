import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// Lawrence msg 19643 ("left alignment here is bad", screenshot of the sidebar's top): the pins, Home's house and a
/// favicon started 1 to 5 pt right of the text-only titles ("Stripe…", "Pinning…"), each glyph centered in the 16 pt
/// icon column at its own ink width, so the left edge was ragged in three places. The look contract: every workspace
/// row's first ink (a favicon, an emoji, a symbol, or a text-only title) starts at the row inset, while Home's glyph and
/// the pins center in the icon column (https://github.com/manaflow-ai/cmux/issues/38061); every
/// icon column box has one x and one width; a title after a leading glyph starts at one text x. A text-only row keeps
/// its title at the inset (Lawrence msg 11405, `SidebarLookContractTests.titlesStartAsFarLeftAsTheRowAllows`).
@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarLeadingEdgeTests {
    typealias Case = HomePinnedRowAlignmentTests.Case

    static let home = LayoutItem(id: LayoutItemID("itm_edge_home"), ref: .builtIn(.home))
    static let pins = ["perf", "chief"].map { LayoutItem(id: LayoutItemID("itm_edge_pin_\($0)"), ref: .workspace("local:ws-edge-pin-\($0)")) }
    static let stripe = WorkspaceID("ws-edge-stripe"), web = WorkspaceID("ws-edge-web"), rocket = WorkspaceID("ws-edge-rocket")
    static let chipped = WorkspaceID("ws-edge-chip"), symbol = WorkspaceID("ws-edge-symbol"), pinning = WorkspaceID("ws-edge-pinning")
    /// Workspace rows that lead with an icon.
    static let iconRows = [web, rocket, chipped, symbol]
    /// Device pixels at 2x: frames snap to half points.
    static let tolerance: CGFloat = 0.5

    /// A favicon whose disc leaves a transparent margin inside its square, as many sites' icons do.
    static let favicon: SidebarFavicon = {
        let side = 32
        let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.26, green: 0.52, blue: 0.96, alpha: 1))
        context.fillEllipse(in: CGRect(x: 3, y: 3, width: side - 6, height: side - 6))
        return SidebarFavicon(context.makeImage()!)
    }()

    /// The sidebar's top as Lawrence's shot drew it: Home, two pinned workspaces (leading pins), then text-only rows
    /// around a favicon row, an emoji row (bare and on a chip) and a symbol row.
    static func list(width: CGFloat) -> (SidebarListView, NSWindow) {
        _ = NSApplication.shared
        let top = LayoutSection(id: SidebarLayoutDocument.topSectionID, region: .top, look: .builtIn, arrangement: .list, items: [home])
        let pinned = SidebarLayoutDocument.pinnedSection(items: pins)
        var infos: [LayoutItemID: SidebarItemInfo] = [home.id: .fallback(for: home)]
        for (pin, title) in zip(pins, ["cmux Performance Lead", "Chief TUI + fast iteration"]) {
            var info = SidebarItemInfo(title: title, symbol: "textformat")
            info.textOnly = true
            info.workspace = WorkspaceID(pin.ref.value.replacingOccurrences(of: "local:", with: ""))
            infos[pin.id] = info
        }
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let model = SidebarModel(sections: [
            SidebarSection(kind: .custom(SidebarCustomSection(id: top.id.rawValue)), nodes: []),
            SidebarSection(kind: .custom(SidebarCustomSection(id: pinned.id.rawValue)), nodes: []),
            SidebarSection(kind: .machine(machine), nodes: [
                .workspace(SidebarWorkspace(id: stripe, title: "Stripe checkout")),
                .workspace(SidebarWorkspace(id: web, title: "Web search", icon: .favicon(favicon))),
                .workspace(SidebarWorkspace(id: rocket, title: "Ship it", icon: .emoji("🚀"))),
                .workspace(SidebarWorkspace(id: chipped, title: "Launch", icon: .emoji("🎯", chip: .green))),
                .workspace(SidebarWorkspace(id: symbol, title: "Build fleet", icon: .symbol("hammer"))),
                .workspace(SidebarWorkspace(id: pinning, title: "Pinning rules")),
            ]),
        ])
        let list = SidebarListView(model: model)
        var metrics = SidebarRegionMetrics.standard
        metrics.trailingTrim = SidebarStyle.rowTrailingTrim
        list.blocks = SidebarListBlocks(sections: [top.id.rawValue: top, pinned.id.rawValue: pinned], infos: infos, collapsed: [],
                                        look: .quiet, metrics: metrics, drawsLines: false, appHeights: [:])
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: width, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 800))
        window.contentView = root
        list.frame = root.bounds
        root.addSubview(list)
        window.orderFrontRegardless()
        list.reload(animated: false)
        list.layoutSubtreeIfNeeded()
        list.rowViews.values.forEach { $0.layoutSubtreeIfNeeded() }
        for region in list.blockRegions { region.itemViews.values.forEach { $0.layoutSubtreeIfNeeded(); $0.layout() } }
        return (list, window)
    }

    /// The x where `view`'s drawn ink starts, in `view`'s coordinates: the view drawn at 2x, the leftmost column with a
    /// pixel at least a quarter opaque (`SidebarGlyphInk`'s threshold). Nil when it draws nothing.
    static func inkMinX(_ view: NSView) throws -> CGFloat? {
        view.subviews.forEach { $0.layoutSubtreeIfNeeded() }
        view.layoutSubtreeIfNeeded()
        let size = view.bounds.size
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = size
        view.cacheDisplay(in: view.bounds, to: rep)
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) >= 0.25 {
                return CGFloat(x) / 2
            }
        }
        return nil
    }

    static func x(_ list: SidebarListView, _ value: CGFloat, in view: NSView) -> CGFloat {
        list.convert(NSPoint(x: value, y: 0), from: view).x
    }

    /// The row inset: where a text-only workspace row's title starts, in list points.
    static func inset(_ list: SidebarListView) throws -> CGFloat {
        list.frame(for: try #require(list.displayed.row(for: .workspace(stripe)))).minX + SidebarStyle.horizontalInset
    }

    /// Every row's first ink starts at the row inset: Home's house, each pin, each workspace icon and the text-only
    /// titles ("Stripe…", "Pinning…"). Lawrence 2026-11-09 ("home/pin icons not left aligned with 'Fix…'"): Home's glyph
    /// and the pins centered in the icon column (#38061), so their ink started 2 to 4 pt right of the titles below.
    @Test(arguments: HomePinnedRowAlignmentTests.cases)
    func everyRowsFirstInkStartsAtTheInset(_ c: Case) throws {
        try SidebarGroupRailAlignmentTests.with(c.density, c.minimal, textSize: c.textSize) {
            let (list, window) = Self.list(width: c.width)
            defer { window.close() }
            let inset = try Self.inset(list)
            var starts: [(String, CGFloat)] = []
            let home = try HomePinnedRowAlignmentTests.item(list, Self.home.id)
            starts.append(("Home's glyph", Self.x(list, try #require(home.glyphInkFrame, "Home drew no glyph").minX, in: home)))
            for pin in Self.pins {
                let row = try HomePinnedRowAlignmentTests.item(list, pin.id)
                starts.append(("\(pin.id.rawValue)'s pin", Self.x(list, try #require(row.pinInkFrame, "no pin drew").minX, in: row)))
            }
            for id in Self.iconRows {
                let row = try HomePinnedRowAlignmentTests.row(list, id)
                let ink = try #require(try Self.inkMinX(row.icon), "\(id.rawValue) drew no icon")
                starts.append(("\(id.rawValue)'s icon", Self.x(list, ink, in: row.icon)))
            }
            for id in [Self.stripe, Self.pinning] {
                let row = try HomePinnedRowAlignmentTests.row(list, id)
                starts.append(("\(id.rawValue)'s title", Self.x(list, row.title.frame.minX, in: row)))
            }
            for (name, x) in starts {
                #expect(abs(x - inset) <= Self.tolerance, "\(c.testDescription): \(name) starts at \(x), the row inset is \(inset)")
            }
        }
    }

    /// Every leading icon column box (Home's, each pin's, each workspace icon's) has one x and one width.
    @Test(arguments: HomePinnedRowAlignmentTests.cases)
    func everyIconBoxHasOneXAndOneWidth(_ c: Case) throws {
        try SidebarGroupRailAlignmentTests.with(c.density, c.minimal, textSize: c.textSize) {
            let (list, window) = Self.list(width: c.width)
            defer { window.close() }
            var boxes: [(String, CGRect)] = []
            for id in [Self.home.id] + Self.pins.map(\.id) {
                let row = try HomePinnedRowAlignmentTests.item(list, id)
                let box = row.leadingColumnFrame
                try #require(box.width > 0, "\(c.testDescription): \(id.rawValue) has no icon column")
                boxes.append((id.rawValue, list.convert(box, from: row)))
            }
            for id in Self.iconRows {
                let row = try HomePinnedRowAlignmentTests.row(list, id)
                boxes.append((id.rawValue, list.convert(row.icon.frame, from: row)))
            }
            let first = try #require(boxes.first).1
            for (name, box) in boxes {
                #expect(abs(box.minX - first.minX) <= Self.tolerance && abs(box.width - first.width) <= Self.tolerance,
                        "\(c.testDescription): \(name)'s icon box \(box.minX) + \(box.width), Home's \(first.minX) + \(first.width)")
            }
        }
    }

    /// The title after a leading glyph (Home's label, each pinned title, each icon row's title) starts at one text x,
    /// right of the icon column.
    @Test(arguments: HomePinnedRowAlignmentTests.cases)
    func iconRowsTitlesStartAtOneTextX(_ c: Case) throws {
        try SidebarGroupRailAlignmentTests.with(c.density, c.minimal, textSize: c.textSize) {
            let (list, window) = Self.list(width: c.width)
            defer { window.close() }
            var titles: [(String, CGFloat)] = []
            for id in [Self.home.id] + Self.pins.map(\.id) {
                let row = try HomePinnedRowAlignmentTests.item(list, id)
                titles.append((id.rawValue, Self.x(list, row.titleFrame.minX, in: row)))
            }
            for id in Self.iconRows {
                let row = try HomePinnedRowAlignmentTests.row(list, id)
                titles.append((id.rawValue, Self.x(list, row.title.frame.minX, in: row)))
            }
            let home = try #require(titles.first).1
            let inset = try Self.inset(list)
            #expect(home >= inset + SidebarStyle.iconColumnBox, "\(c.testDescription): Home's label at \(home), inside the icon column")
            for (name, x) in titles {
                #expect(abs(x - home) <= Self.tolerance, "\(c.testDescription): \(name)'s title at \(x), Home's label at \(home)")
            }
        }
    }
}
