import AppKit
@testable import CmuxNextDesign
import CmuxNextDesignTokens
import CmuxNextSettings
@testable import CmuxNextSidebar
@testable import CmuxNextTabs
import CmuxNextTestSupport
import CmuxTheme
import Foundation
import Testing

/// A look's layout and proportions (`appearance.metrics.*`; Leo, 2026-11-19: "i think y'all also ought to emulate the
/// things for context menu styling and such maybne in those repos too and the layout and proportions as well"; "if it
/// cant be hot swapped, that's probably an issue with our api/sdk"): a window's top part built from the app's own views
/// (the header's icon buttons, the sidebar list, a pane's tab strip) under four looks: cmux's own (no key set), Claude's
/// (a 44 pt header, a 284 pt sidebar, header buttons on a rounded square), Codex's and Studio's, measured from the
/// design references. Written under `look-proportions-gallery/` with `all.png`, bundled to
/// `look-proportions-gallery.tar` for `cmux-ci run --artifact`. Runs only with `CMUX_TEST_REQUIRE_GUI=1`; the default
/// and hot-swap checks run always.
@MainActor @Suite(.serialized, .closesItsWindows) struct AALookProportionsGalleryTests {
    /// One look's `appearance.metrics.*` values, as its theme file sets them.
    struct Look {
        let name: String
        let metrics: [MetricKey: CGFloat]
    }

    /// Each pack's measurements (~/Projects/looks/chameleon-*/MENUS-AND-PROPORTIONS.md, from the design references).
    static let looks: [Look] = [
        Look(name: "cmux", metrics: [:]),
        // Claude desktop: a 40 pt header (Leo: about 44) with a hairline under it, a 288 pt sidebar, 26 pt rows, header
        // buttons 21.5 pt on a 24.5 pt pitch, the one that is on over a 5 pt rounded square at 14% of the text color.
        Look(name: "claude", metrics: [.titlebarHeight: 40, .sidebarWidth: 288, .sidebarRowHeight: 26, .sidebarRowInset: 8,
                                       .sidebarRowPadding: 10, .sidebarRowGap: 0.5, .toolbarButtonSize: 21.5, .toolbarButtonGap: 3,
                                       .toolbarButtonCornerRadius: 5, .toolbarButtonActiveFill: 0.14, .headerDivider: 1,
                                       .composerPadding: 14, .composerMinHeight: 44]),
        // Codex: a 46 pt header with no divider, a 306 pt sidebar, 30 pt rows, 28 pt header chips.
        Look(name: "codex", metrics: [.titlebarHeight: 46, .sidebarWidth: 306, .sidebarRowHeight: 30, .sidebarRowInset: 8,
                                      .sidebarRowPadding: 8, .sidebarRowGap: 1, .toolbarButtonSize: 28, .toolbarButtonGap: 6,
                                      .toolbarButtonCornerRadius: 14, .toolbarButtonActiveFill: 0.1, .headerDivider: 0,
                                      .composerPadding: 13, .composerMinHeight: 52]),
        // Studio: a 52 pt header with no divider, a 255 pt sidebar, 78 pt two-line thread cards inset 8 pt, 14 pt glyphs
        // on a 32 pt pitch.
        Look(name: "studio", metrics: [.titlebarHeight: 52, .sidebarWidth: 255, .sidebarRowHeight: 28, .sidebarRowHeightWithSubtitle: 78,
                                       .sidebarRowInset: 8, .sidebarRowPadding: 10, .sidebarRowGap: 2, .toolbarButtonSize: 28,
                                       .toolbarButtonGap: 4, .toolbarButtonCornerRadius: 6, .headerDivider: 0, .spacingScale: 1.25,
                                       .composerPadding: 16, .composerMinHeight: 48]),
    ]

    /// Sets `look`'s metrics for `body` at Default density, and puts every override back after.
    static func with<T>(_ look: Look, _ body: () throws -> T) rethrows -> T {
        let design = DesignSettings.shared
        let before = (design.densityTokens, design.overrides)
        defer {
            design.densityTokens = before.0
            for key in MetricKey.allCases { design.setOverride(key, before.1[key]) }
        }
        design.densityTokens = DensityPreset.cozy.tokens
        for key in MetricKey.allCases { design.setOverride(key, look.metrics[key]) }
        return try body()
    }

    static func sections() -> [SidebarSection] {
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let titles = ["New session", "Header proportions", "Sidebar rows", "Toolbar buttons", "Composer padding"]
        let rows = titles.enumerated().map { index, title in
            SidebarNode.workspace(SidebarWorkspace(id: WorkspaceID("w-\(index)"), title: title, activity: index == 1 ? .busy(progress: nil) : .idle))
        }
        return [SidebarSection(kind: .machine(machine), nodes: rows)]
    }

    struct Scene {
        let window: NSWindow
        let root: NSView
        let header: [TitlebarBandButton]
        let tools: [TitlebarBandButton]
        let list: SidebarListView

        func image() throws -> CGImage {
            for view in AANestedGroupsGalleryTests.all(root) {
                view.layer?.removeAllAnimations()
                view.needsDisplay = true
                view.displayIfNeeded()
            }
            CATransaction.flush()
            let rep = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
            root.cacheDisplay(in: root.bounds, to: rep)
            return try #require(rep.cgImage)
        }
    }

    static let width: CGFloat = 900, height: CGFloat = 360

    /// The header band (sidebar toggle, Back and Forward at the leading edge; the pane's tools at the trailing edge, the
    /// terminal one lit as the active panel), the sidebar list under it and a pane's tab strip, laid out from the live
    /// metrics as the window root does.
    static func scene(dark: Bool) throws -> Scene {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: width, height: height), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        root.wantsLayer = true
        root.appearance = window.appearance
        window.contentView = root
        let input = try AANestedGroupsGalleryTests.input(dark ? "Soft Blue" : "Soft Blue Light")
        _ = ThemeScope.app.store.apply(input)
        let scope = ThemeScope(level: .room)
        scope.setOverride(ThemeSpec(dark ? "Soft Blue" : "Soft Blue Light"), input: input, animated: false)
        scope.root(root)
        root.layer?.backgroundColor = scope.perform { Palette.surfaceBackground.withAlphaComponent(1) }.cgColor

        let titlebar = Metrics.titlebarHeight, sidebar = Metrics.sidebarWidth
        let side = TopRowSpacing.buttonSide, gap = TopRowSpacing.groupGap
        let buttonY = height - (titlebar + side) / 2
        func row(_ symbols: [String], from x: CGFloat) -> [TitlebarBandButton] {
            symbols.enumerated().map { index, symbol in
                let button = TitlebarBandButton(symbol: symbol)
                button.frame = NSRect(x: x + CGFloat(index) * (side + gap), y: buttonY, width: side, height: side)
                root.addSubview(button)
                return button
            }
        }
        // The lights' room, then the band, as the window root reserves it.
        let header = row(["sidebar.left", "chevron.left", "chevron.right"], from: Metrics.trafficLightInset)
        let toolSymbols = ["list.bullet", "apple.terminal", "plus.forwardslash.minus", "globe", "folder"]
        let toolsWidth = CGFloat(toolSymbols.count) * side + CGFloat(toolSymbols.count - 1) * gap
        let tools = row(toolSymbols, from: width - Metrics.space4 - toolsWidth)
        tools[1].hover.state.lit = true // the open panel's button on its active fill
        let divider = CALayer() // the header's hairline
        divider.frame = CGRect(x: sidebar, y: height - titlebar, width: width - sidebar, height: 1)
        divider.backgroundColor = scope.perform { Palette.separator }.cgColor
        root.layer?.addSublayer(divider)

        let model = SidebarModel(sections: sections())
        model.activeWorkspaceID = WorkspaceID("w-1")
        let list = SidebarListView(model: model)
        list.frame = NSRect(x: 0, y: 0, width: sidebar, height: height - titlebar)
        root.addSubview(list)

        let stripHeight = PaneChromeMetrics.current.resolvedStripHeight(scale: window.backingScaleFactor)
        let tabs = ["shell", "Header", "browser"].enumerated().map { TabItem(id: TabID("tab\($0.offset)"), title: $0.element) }
        let strip = TabStripView(model: TabStripModel(tabs: tabs, selectedID: TabID("tab1")))
        strip.dragsWindowFromEmptySpace = false
        strip.frame = NSRect(x: sidebar, y: height - titlebar - stripHeight, width: width - sidebar, height: stripHeight)
        root.addSubview(strip)

        window.orderFrontRegardless()
        list.reload(animated: false)
        root.layoutSubtreeIfNeeded()
        strip.layoutSubtreeIfNeeded()
        return Scene(window: window, root: root, header: header, tools: tools, list: list)
    }

    /// With no key set, every proportion is today's: the band's button is the sidebar header's height, its gap three
    /// tenths of it, a button's corner the tab ratio and the spacing grid the density's.
    @Test func noKeyDrawsTodaysLayout() {
        Self.with(Self.looks[0]) {
            #expect(TopRowSpacing.buttonSide == Metrics.sidebarHeaderHeight)
            #expect(TopRowSpacing.groupGap == (Metrics.sidebarHeaderHeight * 0.3 * 2).rounded() / 2)
            #expect(Metrics.toolbarButtonCornerRadius(side: 28) == Metrics.buttonCornerRadius(proportionalTo: 28))
            #expect(Metrics.space4 == Metrics.scale(Metrics.tokens.space(ChromeTunables.space4.value)))
            #expect(SidebarRowTuning.outerInset.value == (Metrics.densityToken("sidebarRowInset") ?? Metrics.space3))
            #expect(SidebarDensityTokens.rowHeightWithSubtitle == SidebarDensityTokens.rowHeight + SidebarStyle.detailLineHeight)
            #expect(PaneToolbarView.toolGap == Metrics.space1 / 2)
            let script = DesignSettings.shared.interfaceScaleScript()
            #expect(script.contains("'--cmux-composer-inset', ''") && script.contains("'--cmux-composer-box', ''"))
        }
    }

    /// A look's keys reach the views that draw them, and taking them off puts today's back: what a theme file applied
    /// or removed does live.
    @Test func aLookAppliesAndComesOffLive() {
        let before = (TopRowSpacing.buttonSide, TopRowSpacing.groupGap, Metrics.space4, SidebarRowTuning.rowGap.value)
        Self.with(Self.looks[1]) {
            #expect(TopRowSpacing.buttonSide == 21.5)
            #expect(TopRowSpacing.groupGap == 3)
            #expect(PaneToolbarView.toolGap == 3)
            #expect(Metrics.toolbarButtonCornerRadius(side: 21.5) == 5)
            #expect(Metrics.toolbarButtonCornerRadius(side: 8) == 4, "never past a circle")
            #expect(SidebarRowTuning.outerInset.value == 8)
            #expect(SidebarRowTuning.contentInset.value == 10)
            #expect(SidebarRowTuning.rowGap.value == 0.5)
            #expect(Metrics.tabRowDividerStrength == 1)
            #expect(abs((ChromeHover.fillColor(ChromeHover.State(lit: true))?.alphaComponent ?? 0) - 0.14) < 0.001)
            let script = DesignSettings.shared.interfaceScaleScript()
            #expect(script.contains("'--cmux-composer-inset', '14px'"))
            #expect(script.contains("'--cmux-composer-box', '44px'"))
        }
        Self.with(Self.looks[3]) {
            let grid = Metrics.tokens.space(ChromeTunables.space4.value)
            #expect(Metrics.space4 == Metrics.scale(DensityTokens.half(grid * 1.25)))
            #expect(SidebarDensityTokens.rowHeightWithSubtitle == 78)
            #expect(Metrics.tabRowDividerStrength == 0)
        }
        #expect((TopRowSpacing.buttonSide, TopRowSpacing.groupGap, Metrics.space4, SidebarRowTuning.rowGap.value) == before)
    }

    /// A value outside a key's range is clamped, as the schema (and the Rust theme file reader) refuses it.
    @Test func valuesAreClampedToTheirRange() {
        let design = DesignSettings.shared
        let saved = design.overrides
        defer { for key in MetricKey.allCases { design.setOverride(key, saved[key]) } }
        design.setOverride(.toolbarButtonSize, 400)
        design.setOverride(.spacingScale, 0.1)
        #expect(design.overrides[.toolbarButtonSize] == 40)
        #expect(design.overrides[.spacingScale] == 0.5)
        for setting in LayoutMetricSetting.proportions {
            let key = MetricKey(rawValue: setting.name)
            #expect(key != nil, "\(setting.name) is a MetricKey")
            if let key { #expect(DesignSettings.allowedRange(key) == CGFloat(setting.range.lowerBound)...CGFloat(setting.range.upperBound)) }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderGallery() throws {
        let packageRoot = AANestedGroupsGalleryTests.packageRoot
        let out = packageRoot.appending(path: "look-proportions-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var images: [CGImage] = []
        for dark in [true, false] {
            for look in Self.looks {
                let image = try Self.with(look) {
                    let scene = try Self.scene(dark: dark)
                    defer { scene.window.close() }
                    return try scene.image()
                }
                images.append(image)
                try AAGroupHeaderDensityGalleryTests.write(image, to: out.appending(path: "\(look.name)-\(dark ? "dark" : "light").png"))
            }
        }
        // Hot swap: one window, Claude's look applied and taken off without rebuilding it.
        let swapped: [CGImage] = try Self.with(Self.looks[0]) {
            let scene = try Self.scene(dark: true)
            defer { scene.window.close() }
            var frames = [try scene.image()]
            for key in MetricKey.allCases { DesignSettings.shared.setOverride(key, Self.looks[1].metrics[key]) }
            TitlebarBandButton.relayoutAll(in: scene.root)
            scene.root.layoutSubtreeIfNeeded()
            frames.append(try scene.image())
            return frames
        }
        for (index, frame) in swapped.enumerated() {
            try AAGroupHeaderDensityGalleryTests.write(frame, to: out.appending(path: "hot-swap-\(index).png"))
        }

        let columns = Self.looks.count
        let w = images.map(\.width).max() ?? 0, h = images.map(\.height).max() ?? 0, gap = 16, rows = images.count / columns
        let ctx = try #require(CGContext(data: nil, width: columns * w + (columns - 1) * gap, height: rows * h + (rows - 1) * gap,
                                         bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        for (i, image) in images.enumerated() {
            let col = i % columns, row = i / columns
            ctx.draw(image, in: CGRect(x: col * (w + gap), y: (rows - 1 - row) * (h + gap), width: image.width, height: image.height))
        }
        try AAGroupHeaderDensityGalleryTests.write(try #require(ctx.makeImage()), to: out.appending(path: "all.png"))

        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = packageRoot
        tar.arguments = ["cf", "look-proportions-gallery.tar", "look-proportions-gallery"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
    }
}
