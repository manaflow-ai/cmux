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
    @MainActor @Suite(.serialized) struct SidebarSurfaceTests {
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
        /// `appearance.chromeStyle` pins it: the app's default is flat-sidebar-line since 2026-10-16.
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
            defer { load(.object([:])) }
            load(outlined())
            let (window, root) = openRoot()
            defer { window.close() }
            await settle(root) { same(sidebarBackground(root), mainPaneBackground(root)) }
            #expect(same(sidebarBackground(root), mainPaneBackground(root)))
            #expect(same(mainPaneBackground(root), root.themeTokens.surfaceBackground.withAlpha(1)))
        }

        @Test func separateKeepsTheOldShadedSidebar() async {
            defer { load(.object([:])) }
            load(appearance(["sidebarSurface": .string("separate")]))
            let (window, root) = openRoot()
            defer { window.close() }
            await settle(root) { same(sidebarBackground(root), separateSidebar(root)) }
            #expect(same(sidebarBackground(root), separateSidebar(root)))
            #expect(same(mainPaneBackground(root), root.themeTokens.surfaceBackground.withAlpha(1)))
        }

        @Test func switchingTheSettingRepaintsTheOpenWindow() async {
            defer { load(.object([:])) }
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
            defer { load(.object([:])) }
            let diagnostics = load(outlined(["sidebarSurface": .string("purple")]))
            #expect(diagnostics.contains { $0.path == "appearance.sidebarSurface" && $0.kind == .invalidValue })
            let (window, root) = openRoot()
            defer { window.close() }
            await settle(root) { same(sidebarBackground(root), mainPaneBackground(root)) }
            #expect(same(sidebarBackground(root), mainPaneBackground(root)))
        }

        /// With `appearance.borders` none no pane outline or edge line parts the sidebar from the
        /// main pane, so the shared surface keeps a faint tonal step there: darker than the pane,
        /// lighter than the separate look.
        @Test func withNoLinesTheSidebarKeepsAFaintStep() async {
            defer { load(.object([:])) }
            load(appearance(["borders": .string("none")]))
            let (window, root) = openRoot()
            defer { window.close() }
            let pane = root.themeTokens.surfaceBackground.withAlpha(1)
            func luminance(_ color: ThemeRGB) -> Double { color.relativeLuminance }
            await settle(root) {
                let sidebar = luminance(sidebarBackground(root))
                return sidebar < luminance(pane) && sidebar > luminance(separateSidebar(root))
            }
            #expect(luminance(sidebarBackground(root)) < luminance(pane))
            #expect(luminance(sidebarBackground(root)) > luminance(separateSidebar(root)))
            #expect(same(mainPaneBackground(root), pane))
        }

        /// The default inside the curved main pane: panes are flush and divided by one line, with no
        /// outline beside the sidebar, so the shared surface keeps the faint step there.
        @Test func byDefaultFlushPanesKeepAFaintStepBesideTheSidebar() async {
            load(.object([:]))
            let (window, root) = openRoot()
            defer { window.close() }
            let pane = root.themeTokens.surfaceBackground.withAlpha(1)
            await settle(root) { sidebarBackground(root).relativeLuminance < pane.relativeLuminance }
            #expect(sidebarBackground(root).relativeLuminance < pane.relativeLuminance)
            #expect(sidebarBackground(root).relativeLuminance > separateSidebar(root).relativeLuminance)
            #expect(same(mainPaneBackground(root), pane))
        }

        /// Cards (like dividers and none) draw no pane outline, and the sidebar's edge line is off by
        /// default, so nothing parts the shared surface either: the faint step stays.
        @Test func withoutPaneOutlinesTheSidebarKeepsAFaintStep() async {
            defer { load(.object([:])) }
            load(.object(["layout": .object(["paneSeparation": .string("cards")])]))
            let (window, root) = openRoot()
            defer { window.close() }
            let pane = root.themeTokens.surfaceBackground.withAlpha(1)
            await settle(root) {
                let sidebar = sidebarBackground(root).relativeLuminance
                return sidebar < pane.relativeLuminance && sidebar > separateSidebar(root).relativeLuminance
            }
            #expect(sidebarBackground(root).relativeLuminance < pane.relativeLuminance)
            #expect(sidebarBackground(root).relativeLuminance > separateSidebar(root).relativeLuminance)
            #expect(same(mainPaneBackground(root), pane))
        }
    }
}
