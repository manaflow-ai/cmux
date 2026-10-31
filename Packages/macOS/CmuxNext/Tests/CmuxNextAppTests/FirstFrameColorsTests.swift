import AppKit
import CmuxNextAgentActivity
@testable import CmuxNextApp
@testable import CmuxNextApps
@testable import CmuxNextBrowser
@testable import CmuxNextDesign
@testable import CmuxNextFeed
@testable import CmuxNextRemoteView
@testable import CmuxNextServer
@testable import CmuxNextTasks
import SwiftUI
import Testing

/// Theme sweep 3, batch E: the color structs of Tasks, the feed, the server UI, remote panes and
/// app scenes started as macOS's grays and system orange, red and green until
/// their host resolved its theme scope, so a first frame could draw the system's colors. Their
/// defaults are now the app theme's current tokens (the colors every scope derives from). The
/// workspace color row in a themed menu rings the hovered swatch in the menu's theme accent.
@MainActor @Suite(.serialized) struct FirstFrameColorsTests {
    /// The app theme's tokens now: what a struct shows before its host resolves.
    private static var app: ThemeTokens { ThemeSnapshot.tokens }

    private static func expect(_ color: Color, _ rgb: ThemeRGB, _ name: String) {
        expect(NSColor(color), rgb, name)
    }

    private static func expect(_ color: NSColor, _ rgb: ThemeRGB, _ name: String) {
        #expect(ThemedOverlayColorsTests.same(color, rgb.nsColor), "\(name): \(color) is not the theme's \(rgb.nsColor)")
    }

    @Test func tasksStartInTheAppTheme() {
        let colors = TasksColors()
        Self.expect(colors.primary, Self.app.textPrimary, "primary")
        Self.expect(colors.secondary, Self.app.textSecondary, "secondary")
        Self.expect(colors.separator, Self.app.separator, "separator")
        Self.expect(colors.attention, Self.app.attention, "attention")
        Self.expect(colors.danger, Self.app.danger, "danger")
        Self.expect(colors.success, Self.app.success, "success")
    }

    @Test func theFeedStartsInTheAppTheme() {
        let colors = FeedColors()
        Self.expect(colors.primary, Self.app.textPrimary, "primary")
        Self.expect(colors.tertiary, Self.app.textTertiary, "tertiary")
        Self.expect(colors.selection, Self.app.selectionFill, "selection")
        Self.expect(colors.danger, Self.app.danger, "danger")
    }

    @Test func theServerUIStartsInTheAppTheme() {
        let colors = ServerColors()
        Self.expect(colors.primary, Self.app.textPrimary, "primary")
        Self.expect(colors.hover, Self.app.hoverFill, "hover")
        Self.expect(colors.warning, Self.app.attention, "warning")
        Self.expect(colors.critical, Self.app.danger, "critical")
        Self.expect(colors.ok, Self.app.success, "ok")
    }

    @Test func aRemotePaneStartsInTheAppTheme() {
        let colors = RemotePaneColors()
        Self.expect(colors.textPrimary, Self.app.textPrimary, "textPrimary")
        Self.expect(colors.hoverFill, Self.app.hoverFill, "hoverFill")
        Self.expect(colors.attention, Self.app.attention, "attention")
        Self.expect(colors.success, Self.app.success, "success")
    }

    @Test func anAppSceneStartsInTheAppTheme() {
        let colors = AppSceneColors.fallback
        Self.expect(colors.primary, Self.app.textPrimary, "primary")
        Self.expect(colors.secondary, Self.app.textSecondary, "secondary")
        Self.expect(colors.success, Self.app.success, "success")
        Self.expect(colors.danger, Self.app.danger, "danger")
    }

    /// In a themed menu the workspace color row's hover ring is the menu scope's accent, and a
    /// swatch whose color can't be read is the scope's tertiary ink, not the system gray.
    @Test func theWorkspaceColorRowDrawsInItsMenusTheme() throws {
        let scope = try ThemedOverlayColorsTests.purpleRoom()
        let menu = NSMenu()
        let row = NSMenuItem()
        let strip = MenuSwatchStrip(title: "Color", choices: [], colors: [], current: nil)
        row.view = MenuIdentityHeaderView(field: nil, strip: strip)
        menu.addItem(row)
        menu.themeRows(in: scope)
        let view: NSView = strip
        let hover = view.responds(to: NSSelectorFromString("hoverRingColor")) ? view.value(forKey: "hoverRingColor") as? NSColor : nil
        let ring = try #require(hover, "the row resolves its hover ring in the menu's scope")
        #expect(ThemedOverlayColorsTests.same(ring, scope.perform { Palette.accent }), "\(ring)")
        let unknown = view.responds(to: NSSelectorFromString("unknownSwatchColor")) ? view.value(forKey: "unknownSwatchColor") as? NSColor : nil
        let swatch = try #require(unknown, "an unreadable color draws in the scope's ink")
        #expect(ThemedOverlayColorsTests.same(swatch, scope.perform { Palette.textTertiary }), "\(swatch)")
    }

    /// The cookie card's quiet link starts in the theme's tertiary ink before its card's first theme
    /// pass, never macOS's secondary label gray (theme sweep 3, batch G).
    @Test func theCookieCardsLinkStartsInTheAppTheme() {
        Self.expect(CookieCardLinkButton().color, Self.app.textTertiary, "link")
    }

    /// A session color the CUA host sent unreadably draws the theme's tertiary ink, not the system
    /// gray (theme sweep 3, batch G).
    @Test func anUnreadableSessionColorIsTheAppThemesInk() {
        Self.expect(AgentActivityColor.nsColor(hex: "not-a-color"), Self.app.textTertiary, "fallback")
        Self.expect(AgentActivityColor.nsColor(hex: "#336699"), ThemeRGB(hex: 0x336699), "a readable color is kept")
    }
}
