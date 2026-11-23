import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBrowser
@testable import CmuxNextDaemon
import CmuxNextDesign
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Foundation
import Testing

/// Stills of a real window's top row (the traffic lights, the toolbar band, the first tab and the omnibar) at every
/// built-in density, dark and light, and once more after the workspace's title changed (user 2026-11-19, msgs 40554,
/// 40580, 40586: the top padding, the lights' line and the titlebar's place). Each still is the window's top-left
/// corner with its titlebar, and `numbers.txt` has the measured line and gaps of each. Written under
/// `top-row-gallery/` and bundled to `top-row-gallery.tar` for `cmux-ci run --artifact`, so a run before a change and
/// one after compare. Display workers only.
@MainActor @Suite(.serialized, .closesItsWindows) struct AATopRowGalleryTests {
    static let out = AANestedGroupsGalleryTests.packageRoot.appending(path: "top-row-gallery")

    /// The window with its titlebar, drawn as the window server would (the theme frame holds the lights), cut to its
    /// top-left `width` x `height` points.
    static func shot(_ window: NSWindow, width: CGFloat = 620, height: CGFloat = 120) throws -> CGImage {
        let frame = try #require(window.contentView?.superview)
        for view in AANestedGroupsGalleryTests.all(frame) {
            view.layoutSubtreeIfNeeded()
            view.layer?.removeAllAnimations()
            view.needsDisplay = true
            view.displayIfNeeded()
        }
        CATransaction.flush()
        let rep = try #require(frame.bitmapImageRepForCachingDisplay(in: frame.bounds))
        frame.cacheDisplay(in: frame.bounds, to: rep)
        let image = try #require(rep.cgImage)
        let scale = CGFloat(image.width) / frame.bounds.width
        let crop = CGRect(x: 0, y: 0, width: min(width, frame.bounds.width) * scale, height: min(height, frame.bounds.height) * scale)
        return try #require(image.cropping(to: crop.integral))
    }

    /// The measured top row, in window points from the top-left.
    static func numbers(_ fixture: SidebarMultiViewWindowTests.Fixture) -> String {
        guard let window = fixture.controller.window, let content = window.contentView else { return "no window" }
        let height = content.bounds.height
        func top(_ view: NSView) -> CGRect {
            let rect = view.convert(view.bounds, to: nil)
            return CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
        }
        func f(_ value: CGFloat) -> String { String(format: "%.2f", value) }
        var parts: [String] = []
        if let lights = WindowTitlebar.trafficLightsFrame(in: window) { parts.append("lights mid \(f(height - lights.midY))") }
        parts.append("toggle mid \(f(top(fixture.controller.root.toolbarBand.sidebarToggle).midY))")
        let strips = AANestedGroupsGalleryTests.all(content).compactMap { $0 as? TabStripView }
            .filter { !$0.isHiddenOrHasHiddenAncestor && $0.bounds.width > 1 }
        let card = top(fixture.controller.root.contentHost)
        if let strip = strips.min(by: { top($0).minY < top($1).minY }), let pill = strip.firstTabPillFrame {
            let local = strip.isFlipped ? pill : CGRect(x: pill.minX, y: strip.bounds.height - pill.maxY, width: pill.width, height: pill.height)
            let inWindow = strip.convert(local, to: nil)
            let tab = CGRect(x: inWindow.minX, y: height - inWindow.maxY, width: inWindow.width, height: inWindow.height)
            let rim = WindowTitlebar.topRowRim(in: window)
            parts.append("tab mid \(f(tab.midY)) above tab \(f(tab.minY - rim)) beside tab \(f(tab.minX - card.minX))")
            if let chrome = AANestedGroupsGalleryTests.all(content).compactMap({ $0 as? BrowserChromeView }).first {
                let bar = top(chrome.addressBar), page = top(chrome.contentContainer)
                parts.append("tab to omnibar \(f(bar.minY - tab.maxY)) omnibar to page \(f(page.minY - bar.maxY))")
            }
        }
        parts.append("strip padding \(f(PaneChromeMetrics.current.tabGap(scale: window.backingScaleFactor)))")
        return parts.joined(separator: " | ")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"
            || ProcessInfo.processInfo.environment["CMUX_CI_DISPLAY_ROUTED"] == "1"))
    func renderGallery() async throws {
        try? FileManager.default.removeItem(at: Self.out)
        try FileManager.default.createDirectory(at: Self.out, withIntermediateDirectories: true)
        let design = DesignSettings.shared
        let saved = (design.densityTokens, design.titlebar, design.tabBarPosition)
        defer { (design.densityTokens, design.titlebar, design.tabBarPosition) = saved }
        design.titlebar = .minimal
        design.tabBarPosition = .top
        var lines: [String] = []
        for density in DensityPreset.allCases {
            design.densityTokens = density.tokens
            let fixture = try await SidebarMultiViewWindowTests.Fixture(keys: ["k0"], tree: TopRowGalleryTree.tree())
            defer { fixture.close() }
            let window = try #require(fixture.controller.window)
            for dark in [true, false] {
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                fixture.frame()
                let name = "\(density.rawValue)-\(dark ? "dark" : "light")"
                try AAGroupHeaderDensityGalleryTests.write(Self.shot(window), to: Self.out.appending(path: "\(name).png"))
                lines.append("\(name): \(Self.numbers(fixture))")
            }
            // A title change: AppKit lays its titlebar out again on its own.
            let workspace = try #require(fixture.services.machines.workspace(id: "k0")?.0)
            workspace.name = "Renamed workspace"
            let deadline = ContinuousClock.now + .seconds(5)
            while window.title.contains("Renamed workspace") == false, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
                fixture.frame()
            }
            window.displayIfNeeded()
            let name = "\(density.rawValue)-light-renamed"
            try AAGroupHeaderDensityGalleryTests.write(Self.shot(window), to: Self.out.appending(path: "\(name).png"))
            lines.append("\(name): \(Self.numbers(fixture))")
        }
        try lines.joined(separator: "\n").appending("\n").write(to: Self.out.appending(path: "numbers.txt"), atomically: true, encoding: .utf8)
        print(lines.map { "TOPROWGALLERY|\($0)" }.joined(separator: "\n"))
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = AANestedGroupsGalleryTests.packageRoot
        tar.arguments = ["cf", "top-row-gallery.tar", "top-row-gallery"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
    }
}

/// The gallery's window: one workspace whose pane shows a browser tab (so the omnibar row is there) beside a terminal.
enum TopRowGalleryTree {
    static func tree() -> DaemonTree {
        let pane = PaneSnapshot(id: PaneID(rawValue: 1), activeTab: 0, tabs: [
            TabSnapshot(surface: SurfaceID(rawValue: 2), kind: .browser, title: "Page", url: "https://example.com/"),
            TabSnapshot(surface: SurfaceID(rawValue: 1), title: "~"),
        ])
        var tree = DaemonTree(registryID: "s-local", workspaces: [
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: WorkspaceKey(rawValue: "k0"), name: "k0",
                              screens: [ScreenSnapshot(id: ScreenID(rawValue: 1), layout: .leaf(pane.id), panes: [pane])]),
        ])
        tree.personal = PersonalState(workspaces: [PersonalWorkspace(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: "k0"), index: 0)])
        return tree
    }
}
