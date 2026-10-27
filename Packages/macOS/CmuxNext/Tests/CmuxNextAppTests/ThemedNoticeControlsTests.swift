import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBookmarks
import CmuxNextDaemon
@testable import CmuxNextDaemonRecovery
@testable import CmuxNextDesign
@testable import CmuxNextHistory
@testable import CmuxNextTerminal
import SwiftUI
import Testing

/// Theme sweep 3, batch F: notices and pages that still drew macOS's look in a themed room. The
/// terminal's copy-mode badge sat on a dark HUD blur, the launch failure's Copy Details and the
/// restart notice's Report and Show Log were stock accessory buttons, and History and Bookmarks
/// started in SwiftUI's label grays and system red until their host resolved the page's scope.
/// Under a purple room each now draws the scope's tokens.
@MainActor @Suite(.serialized) struct ThemedNoticeControlsTests {
    /// The app theme's tokens now: what a page's colors show before its host resolves.
    private static var app: ThemeTokens { ThemeSnapshot.tokens }

    private static func expect(_ color: Color, _ rgb: ThemeRGB, _ name: String) {
        let resolved = NSColor(color)
        #expect(ThemedOverlayColorsTests.same(resolved, rgb.nsColor), "\(name): \(resolved) is not the theme's \(rgb.nsColor)")
    }

    private static func buttons(in view: NSView) -> [NSButton] {
        view.subviews.flatMap { ($0 as? NSButton).map { [$0] } ?? buttons(in: $0) }
    }

    /// `button`'s bezel is the scope's selection fill, as every themed notice button's is.
    private static func expectThemeBezel(_ button: NSButton, _ scope: ThemeScope) throws {
        let bezel = try #require(button.bezelColor, "\(button.title) has a theme bezel, not the system's")
        #expect(ThemedOverlayColorsTests.same(bezel, scope.perform { Palette.selectionFill }), "\(button.title): \(bezel)")
    }

    @Test func theCopyModeBadgeSitsOnTheThemesSurface() throws {
        let scope = try ThemedOverlayColorsTests.purpleRoom()
        let badge = TerminalCopyModeBadge()
        scope.root(badge)
        let fill = try #require(badge.layer?.backgroundColor.flatMap(NSColor.init(cgColor:)), "the badge paints a fill")
        #expect(ThemedOverlayColorsTests.same(fill, scope.perform { Palette.elevatedBackground }), "\(fill)")
    }

    @Test func theLaunchFailuresCopyDetailsDrawsTheTheme() throws {
        let scope = try ThemedOverlayColorsTests.purpleRoom()
        _ = NSApplication.shared
        let view = DaemonConnectingView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), deadlines: MainDeadlineRig().deadlines)
        view.apply(.unavailable(.connectFailed(path: "/tmp/cmux-501/tui.sock", errno: ECONNREFUSED)))
        scope.root(view)
        let copy = try #require(Self.buttons(in: view).first { !$0.isHidden }, "Copy Details shows")
        try Self.expectThemeBezel(copy, scope)
    }

    @Test func theRestartNoticesButtonsDrawTheTheme() throws {
        let scope = try ThemedOverlayColorsTests.purpleRoom()
        let notice = RestartNoticePanel(text: "cmux restarted after a problem", onShowLog: {}, onReport: {})
        let surface = try #require(notice.surface)
        scope.root(surface)
        let titled = Self.buttons(in: surface).filter { [CrashStrings.report, CrashStrings.showLog].contains($0.title) }
        #expect(titled.count == 2, "Report and Show Log")
        for button in titled { try Self.expectThemeBezel(button, scope) }
    }

    @Test func historyStartsInTheAppTheme() {
        let colors = HistoryPageColors()
        Self.expect(colors.primary, Self.app.textPrimary, "primary")
        Self.expect(colors.secondary, Self.app.textSecondary, "secondary")
        Self.expect(colors.tertiary, Self.app.textTertiary, "tertiary")
        Self.expect(colors.hover, Self.app.hoverFill, "hover")
        Self.expect(colors.selection, Self.app.selectionFill, "selection")
        Self.expect(colors.separator, Self.app.separator, "separator")
        Self.expect(colors.danger, Self.app.danger, "danger")
    }

    @Test func bookmarksStartInTheAppTheme() {
        let colors = BookmarkPageColors()
        Self.expect(colors.primary, Self.app.textPrimary, "primary")
        Self.expect(colors.secondary, Self.app.textSecondary, "secondary")
        Self.expect(colors.tertiary, Self.app.textTertiary, "tertiary")
        Self.expect(colors.hover, Self.app.hoverFill, "hover")
        Self.expect(colors.selection, Self.app.selectionFill, "selection")
        Self.expect(colors.separator, Self.app.separator, "separator")
        Self.expect(colors.danger, Self.app.danger, "danger")
    }

    /// With `appearance.borders` none, a page's first-frame separator is clear, as `Palette.separator`
    /// is once the host resolves its scope: the border switch applies before the scope does too.
    @Test func aPagesFirstSeparatorFollowsTheBorderSwitch() {
        let settings = DesignSettings.shared
        let saved = settings.borders
        settings.borders = .none
        defer { settings.borders = saved }
        for (name, separator) in [("history", HistoryPageColors().separator), ("bookmarks", BookmarkPageColors().separator)] {
            let alpha = NSColor(separator).usingColorSpace(.sRGB)?.alphaComponent ?? 1
            #expect(alpha == 0, "\(name): borders none draws no separator, not \(NSColor(separator))")
        }
    }
}
