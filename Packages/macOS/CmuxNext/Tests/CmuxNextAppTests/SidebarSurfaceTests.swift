import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextSettings
import CmuxNextSidebar
import Testing

extension MainPaneGutterSuites {
    /// `appearance.sidebarSurface` (Leo 2026-10-12): by default the sidebar draws the main pane's own
    /// surface, with no shade of its own while pane outlines part them and a faint step beside the
    /// default flush, divided panes; "separate" keeps the old look, where the sidebar and the
    /// chrome around the curved main pane are shaded darker than the pane. The setting applies live,
    /// from cmux.json through the settings applier to the open window.
    @MainActor struct SidebarSurfaceTests {
        /// The density and chrome style when the case began (a new value per case): ``reset()`` puts them back.
        private let kept = (density: DesignSettings.shared.densityTokens, style: DesignSettings.shared.chromeStyle)

        /// A window root in a titled, full-size-content window, as the app shows it, sidebar shown.
        func openRoot() -> (NSWindow, WindowRootView) {
            _ = NSApplication.shared
            let root = WindowRootView(sidebar: SidebarContainerView(model: SidebarModel()))
            let window = NSWindow(contentRect: root.frame, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.titlebarAppearsTransparent = true
            window.contentView = root
            root.needsLayout = true
            root.layoutSubtreeIfNeeded()
            return (window, root)
        }

        /// Loads `json` as the cmux.json, the way a settings load applies it. These cases measure the
        /// `default` chrome style's surfaces (curved main pane), so a file without
        /// `appearance.chromeStyle` pins it: the app's default is flat (no card) since 2026-11-07.
        @discardableResult
        func load(_ json: JSONValue) -> [SettingsDiagnostic] {
            var members = json.objectValue ?? [:]
            var look = members["appearance"]?.objectValue ?? [:]
            if look["chromeStyle"] == nil { look["chromeStyle"] = .string("default") }
            members["appearance"] = .object(look)
            let snapshot = CmuxConfigSnapshot.parse(.object(members), validDensities: SettingsApplier.validDensities,
                                                    validMetrics: SettingsApplier.validMetrics)
            return SettingsApplier(registry: ActionRegistry.standard()).apply(snapshot)
        }

        /// Undoes a case's loads: loads an empty file, so every key the case set is back at its default, then puts back
        /// the density and chrome style the case found (the empty file's are Default and `default`, not theirs).
        func reset() {
            load(.object([:]))
            let design = DesignSettings.shared
            if design.densityTokens != kept.density { design.densityTokens = kept.density }
            if design.chromeStyle != kept.style { design.chromeStyle = kept.style }
        }

        func appearance(_ members: [String: JSONValue]) -> JSONValue {
            .object(["appearance": .object(members)])
        }

        /// `appearance` members with outlined panes (`layout.paneSeparation` borders): the pane
        /// outlines part the sidebar from the main pane, so the shared surface takes no step. Inside
        /// the curved main pane the default separation is dividers, which draws no outline.
        func outlined(_ members: [String: JSONValue] = [:]) -> JSONValue {
            .object(["appearance": .object(members), "layout": .object(["paneSeparation": .string("borders")])])
        }

        /// The color the window shows at `point` (root coordinates) under its chrome: the window's
        /// one surface, under the main pane's chrome shade where that shade covers the point.
        func background(at point: CGPoint, in root: WindowRootView) -> ThemeRGB {
            let surface = root.themeTokens.surfaceBackground.withAlpha(1)
            let shade = root.mainPaneShade.layer?.sublayers?.lazy.compactMap { $0 as? CAShapeLayer }.first
            guard let shade, let path = shade.path, path.contains(point, using: .evenOdd),
                  let fill = shade.fillColor.flatMap({ NSColor(cgColor: $0) })?.usingColorSpace(.sRGB) else { return surface }
            return ThemeRGB(red: Double(fill.redComponent), green: Double(fill.greenComponent), blue: Double(fill.blueComponent),
                            alpha: Double(fill.alphaComponent)).composited(over: surface)
        }

        func sidebarBackground(_ root: WindowRootView) -> ThemeRGB {
            background(at: CGPoint(x: root.sidebar.frame.midX, y: root.sidebar.frame.midY), in: root)
        }

        func mainPaneBackground(_ root: WindowRootView) -> ThemeRGB {
            background(at: CGPoint(x: root.contentHost.frame.midX, y: root.contentHost.frame.midY), in: root)
        }

        /// The sidebar's shaded look before this setting: black at the main pane's chrome shade over
        /// the surface.
        func separateSidebar(_ root: WindowRootView) -> ThemeRGB {
            let alpha = root.themeTokens.isDark ? ChromeTunables.mainPaneShadeDark.value : ChromeTunables.mainPaneShadeLight.value
            return ThemeRGB.black.withAlpha(alpha).composited(over: root.themeTokens.surfaceBackground.withAlpha(1))
        }

        func same(_ a: ThemeRGB, _ b: ThemeRGB) -> Bool {
            abs(a.red - b.red) < 0.002 && abs(a.green - b.green) < 0.002 && abs(a.blue - b.blue) < 0.002
        }

        /// Waits for the window to follow a settings change (the main pane observes the settings).
        func settle(_ root: WindowRootView, until condition: () -> Bool) async {
            for _ in 0..<150 where !condition() {
                try? await Task.sleep(for: .milliseconds(10))
                root.layoutSubtreeIfNeeded()
            }
        }

        @Test func withPaneOutlinesTheSidebarDrawsTheMainPanesSurface() async {
            defer { reset() }
            load(outlined())
            let (window, root) = openRoot()
            defer { window.close() }
            await settle(root) { same(sidebarBackground(root), mainPaneBackground(root)) }
            #expect(same(sidebarBackground(root), mainPaneBackground(root)))
            #expect(same(mainPaneBackground(root), root.themeTokens.surfaceBackground.withAlpha(1)))
        }

        @Test func separateKeepsTheOldShadedSidebar() async {
            defer { reset() }
            load(appearance(["sidebarSurface": .string("separate")]))
            let (window, root) = openRoot()
            defer { window.close() }
            await settle(root) { same(sidebarBackground(root), separateSidebar(root)) }
            #expect(same(sidebarBackground(root), separateSidebar(root)))
            #expect(same(mainPaneBackground(root), root.themeTokens.surfaceBackground.withAlpha(1)))
        }

        @Test func switchingTheSettingRepaintsTheOpenWindow() async {
            defer { reset() }
            load(outlined())
            let (window, root) = openRoot()
            defer { window.close() }

            load(outlined(["sidebarSurface": .string("separate")]))
            await settle(root) { same(sidebarBackground(root), separateSidebar(root)) }
            #expect(same(sidebarBackground(root), separateSidebar(root)))

            load(outlined(["sidebarSurface": .string("same")]))
            await settle(root) { same(sidebarBackground(root), mainPaneBackground(root)) }
            #expect(same(sidebarBackground(root), mainPaneBackground(root)))

            // Removing the key from the file returns to the default.
            load(outlined(["sidebarSurface": .string("separate")]))
            await settle(root) { same(sidebarBackground(root), separateSidebar(root)) }
            load(outlined())
            await settle(root) { same(sidebarBackground(root), mainPaneBackground(root)) }
            #expect(same(sidebarBackground(root), mainPaneBackground(root)))
        }

        @Test func aBadValueKeepsTheDefaultAndSaysWhy() async {
            defer { reset() }
            let diagnostics = load(outlined(["sidebarSurface": .string("purple")]))
            #expect(diagnostics.contains { $0.path == "appearance.sidebarSurface" && $0.kind == .invalidValue })
            let (window, root) = openRoot()
            defer { window.close() }
            await settle(root) { same(sidebarBackground(root), mainPaneBackground(root)) }
            #expect(same(sidebarBackground(root), mainPaneBackground(root)))
        }

        /// With `appearance.borders` none no line parts the sidebar from the main pane, and the
        /// shared surface still draws the pane's own color there (Lawrence 2026-10-19: "it should
        /// just have a border on the sidebar, not a different color"; no faint tonal step).
        @Test func withNoLinesTheSidebarStillDrawsTheMainPanesSurface() async {
            defer { reset() }
            load(appearance(["borders": .string("none")]))
            let (window, root) = openRoot()
            defer { window.close() }
            let pane = root.themeTokens.surfaceBackground.withAlpha(1)
            await settle(root) { same(sidebarBackground(root), pane) }
            #expect(same(sidebarBackground(root), pane), "the sidebar is \(sidebarBackground(root)), the pane \(pane)")
            #expect(same(mainPaneBackground(root), pane))
        }

        /// The default inside the curved main pane: the sidebar is the pane's color, parted by its
        /// hairline edge line.
        @Test func byDefaultTheSidebarIsThePanesColorWithAnEdgeLine() async {
            defer { reset() }
            load(.object([:]))
            let (window, root) = openRoot()
            defer { window.close() }
            let pane = root.themeTokens.surfaceBackground.withAlpha(1)
            await settle(root) { same(sidebarBackground(root), pane) }
            #expect(same(sidebarBackground(root), pane), "the sidebar is \(sidebarBackground(root)), the pane \(pane)")
            #expect(Metrics.sidebarBorderWidth > 0, "the sidebar shows no edge line")
            #expect(same(mainPaneBackground(root), pane))
        }

        /// Cards draw no pane outline; the shared surface still draws the pane's color beside them.
        @Test func withoutPaneOutlinesTheSidebarStillDrawsThePanesColor() async {
            defer { reset() }
            load(.object(["layout": .object(["paneSeparation": .string("cards")])]))
            let (window, root) = openRoot()
            defer { window.close() }
            let pane = root.themeTokens.surfaceBackground.withAlpha(1)
            await settle(root) { same(sidebarBackground(root), pane) }
            #expect(same(sidebarBackground(root), pane), "the sidebar is \(sidebarBackground(root)), the pane \(pane)")
            #expect(same(mainPaneBackground(root), pane))
        }

        /// Every window style on one surface (all but the shaded ones, `two-tone`, `floating` and
        /// `blocks`, whose sidebar shares the shaded window chrome) draws the sidebar in the
        /// window's own color and parts it with a hairline on its edge; `bare` keeps no lines.
        @Test(arguments: ChromeStyle.allCases)
        func everyWindowStyleDrawsTheSidebarOnTheWindowsColor(style: ChromeStyle) async {
            defer { reset() }
            load(appearance(["chromeStyle": .string(style.rawValue)]))
            let (window, root) = openRoot()
            defer { window.close() }
            let surface = root.themeTokens.surfaceBackground.withAlpha(1)
            if style == .twoTone || style == .floating || style == .blocks {
                // The sidebar is the shaded chrome itself: the color of the window's titlebar band.
                let titlebar = background(at: CGPoint(x: root.contentHost.frame.midX, y: root.bounds.maxY - 1), in: root)
                await settle(root) { same(sidebarBackground(root), titlebar) }
                #expect(same(sidebarBackground(root), titlebar), "\(style): the sidebar is \(sidebarBackground(root)), the titlebar \(titlebar)")
                return
            }
            await settle(root) { same(sidebarBackground(root), surface) }
            #expect(same(sidebarBackground(root), surface), "\(style): the sidebar is \(sidebarBackground(root)), the window \(surface)")
            if style == .bare {
                #expect(Metrics.sidebarBorderWidth == 0, "bare shows a sidebar line")
            } else {
                #expect(Metrics.sidebarBorderWidth > 0, "\(style): the sidebar shows no edge line")
                #expect(Metrics.sidebarBorderWidth <= 1, "\(style): the sidebar line is \(Metrics.sidebarBorderWidth) pt, not a hairline")
            }
        }

        /// A case leaves the process's density and chrome style as it found them. The empty load that undoes a case
        /// applies the file's Default density (#37274) and the `default` style ``load(_:)`` pins, and a suite that runs
        /// later in the same process reads them: NewTabReplaceInPlaceTests.swift:210 measured its tab slots at Default after this suite (tip run
        /// 42718506331).
        @Test func aCaseLeavesTheDensityAndChromeStyleItFound() {
            let design = DesignSettings.shared
            let before = (density: design.densityTokens, style: design.chromeStyle)
            defer { (design.densityTokens, design.chromeStyle) = before }
            design.densityTokens = DensityPreset.spacious.tokens
            design.chromeStyle = .bare
            let suite = SidebarSurfaceTests()
            suite.load(outlined(["sidebarSurface": .string("separate")]))
            suite.reset()
            #expect(design.densityTokens == DensityPreset.spacious.tokens, "the density is \(design.densityTokens.id)")
            #expect(design.chromeStyle == .bare, "the chrome style is \(design.chromeStyle)")
        }
    }
}
