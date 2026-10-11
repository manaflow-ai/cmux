import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextHome
@testable import CmuxNextTerminal
import Testing

/// Home's Chief settings, the terminal's status pill and copy-mode badge, and Home's sheets draw
/// in the theme of the scope they sit in (cx-wqn5 stress pass): under a saturated purple theme
/// their text is the theme's ink and their fills the theme's surfaces, not macOS's gray labels or
/// a fixed dark pill.
@MainActor @Suite(.serialized) struct ThemedOverlayColorsTests {
    /// A room with a saturated purple theme, unlike macOS's own grays.
    static func purpleRoom() throws -> ThemeScope {
        let scope = ThemeScope(level: .room)
        let input = ThemeInput(background: ThemeRGB(hex: 0x2B1650), foreground: ThemeRGB(hex: 0xF4E3FF))
        scope.setOverride(try #require(ThemeSpec("Stress Purple")), input: input, animated: false)
        return scope
    }

    @Test func homeChiefSettingsDrawInTheTheme() throws {
        let scope = try Self.purpleRoom()
        let sidebar = HomeChiefSidebar(muxHome: FileManager.default.temporaryDirectory, source: UnreachableEngine())
        scope.root(sidebar)

        let fill = try #require(sidebar.layer?.backgroundColor.flatMap(NSColor.init(cgColor:)))
        #expect(Self.same(fill, scope.perform { Palette.sidebarBackground }))
        let labels = Self.labels(in: sidebar)
        #expect(labels.count > 4)
        for label in labels {
            #expect(Self.isThemeInk(label.textColor, scope), "\(label.stringValue)")
        }
    }

    @Test func theTerminalStatusPillDrawsInTheTheme() throws {
        let scope = try Self.purpleRoom()
        let banner = TerminalStatusBanner()
        banner.show(.exited)
        scope.root(banner)

        let fill = try #require(banner.layer?.backgroundColor.flatMap(NSColor.init(cgColor:)))
        #expect(Self.same(fill, scope.perform { Palette.elevatedBackground }))
        let label = try #require(Self.labels(in: banner).first)
        #expect(Self.isThemeInk(label.textColor, scope))
    }

    @Test func theCopyModeBadgeDrawsInTheTheme() throws {
        let scope = try Self.purpleRoom()
        let badge = TerminalCopyModeBadge()
        scope.root(badge)

        let label = try #require(Self.labels(in: badge).first)
        #expect(Self.isThemeInk(label.textColor, scope))
        let edge = try #require(badge.layer?.borderColor.flatMap(NSColor.init(cgColor:)))
        #expect(Self.same(edge, scope.perform { Palette.separator }))
    }

    @Test func homeSheetNotesDrawInTheTheme() throws {
        let scope = try Self.purpleRoom()
        let compose = HomeComposeSheet(contacts: [])
        let invite = HomeInviteSheet(pending: ["ada@example.com"])
        for sheet in [compose, invite] as [HomeSheetController] {
            scope.root(sheet.view)
            for label in Self.labels(in: sheet.view) {
                #expect(Self.isThemeInk(label.textColor, scope), "\(label.stringValue)")
            }
        }
    }

    // MARK: Helpers

    /// Every read-only text field under `view`.
    static func labels(in view: NSView) -> [NSTextField] {
        var found: [NSTextField] = []
        if let field = view as? NSTextField, !field.isEditable, !(field is NSSearchField) { found.append(field) }
        for subview in view.subviews { found += labels(in: subview) }
        return found
    }

    /// The scope's text colors: primary, secondary, tertiary or danger.
    static func isThemeInk(_ color: NSColor?, _ scope: ThemeScope) -> Bool {
        guard let color else { return false }
        let inks = scope.perform { [Palette.textPrimary, Palette.textSecondary, Palette.textTertiary, Palette.danger] }
        return inks.contains { same(color, $0) }
    }

    static func same(_ lhs: NSColor, _ rhs: NSColor) -> Bool {
        guard let lhs = lhs.usingColorSpace(.sRGB), let rhs = rhs.usingColorSpace(.sRGB) else { return false }
        return abs(lhs.redComponent - rhs.redComponent) < 0.01 && abs(lhs.greenComponent - rhs.greenComponent) < 0.01
            && abs(lhs.blueComponent - rhs.blueComponent) < 0.01 && abs(lhs.alphaComponent - rhs.alphaComponent) < 0.01
    }
}

/// A Chief whose brain is not running: the settings show their failure note.
private struct UnreachableEngine: HomeChiefEngineSource {
    var isLocal: Bool { true }
    var place: String? { nil }
    func read() async throws(HomeChiefEngineError) -> HomeChiefSnapshot { throw .localUnreachable }
    func set(_ key: String, _ value: String?) async throws(HomeChiefEngineError) -> HomeChiefSnapshot { throw .localUnreachable }
}
