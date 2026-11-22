import AppKit
import CmuxNextDesign
@testable import CmuxNextPages
import Foundation
import Testing

/// A page draws in its own view's theme scope (#28867). A workspace with a background picture
/// keeps its pages clear over that picture whatever the app scope shows. The page's theme was
/// built outside the scope, so `WindowBackdrop.current` read the app's (no picture), saw an
/// opaque window, and painted the surface color solid: the agent chat showed a black pane
/// instead of the wallpaper after a workspace switch.
@MainActor @Suite(.serialized) struct PageWebViewScopeThemeTests {
    private let descriptor = PageDescriptor(id: "test.scope-theme", resource: "scope-theme", namespaces: [])

    /// The alpha of a `rgba(r, g, b, a)` value.
    private static func alpha(_ css: String?) -> Double? {
        guard let css, css.hasPrefix("rgba("), css.hasSuffix(")") else { return nil }
        return css.dropLast().split(separator: ",").last.flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
    }

    @Test func aPageInAWorkspaceWithAPictureStaysClearOverIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("page-scope-theme-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("<!doctype html><title>Page</title>".utf8).write(to: root.appendingPathComponent("index.html"))
        // The see-through branch is under test: Blacksmith's macOS VMs have Reduce Transparency
        // on, which paints every surface opaque whatever the scope decides.
        let savedReduceTransparency = ReduceTransparency.shared.override
        ReduceTransparency.shared.override = false
        defer { ReduceTransparency.shared.override = savedReduceTransparency }

        // The app shows no picture; only this workspace does.
        try #require(ThemeScope.app.backdropSelection == nil)
        let workspace = ThemeScope(level: .workspace)
        workspace.pinBackdrop(.selection(.art(.vanGoghStarryNight)))
        defer { workspace.pinBackdrop(.inherit) }
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        workspace.root(content)
        let page = try #require(PageWebView(descriptor: descriptor, root: root, routes: [], chromium: nil))
        defer { page.close() }
        content.addSubview(page)

        // What the scope itself decides for a page drawn in it: see-through over its picture.
        let inScope = page.performWithTheme {
            WindowBackdrop.current(page.themeTokens).panesPaintBackground
        }
        #expect(inScope == false)

        // Outside any scope the app's (no picture) decides, and its window is opaque: the case
        // this test needs, or it would pass without the fix.
        try #require(Self.alpha(WebTheme(page.themeTokens, surface: .internalPage).variables["--cmux-surface-background"]) == 1)

        let theme = page.currentTheme()
        #expect(Self.alpha(theme.variables["--cmux-surface-background"]) == 0)
    }
}
