import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextHome
@testable import CmuxNextHomeEngine
@testable import CmuxNextRemoteBrowser
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
        let settings = HomeChiefSettingsView(muxHome: FileManager.default.temporaryDirectory, source: UnreachableEngine())
        scope.root(settings)

        // The popover's glass card is the surface (HomeChiefSettingsPopover); the content's text draws the theme.
        let labels = Self.labels(in: settings)
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
        let invite = HomeInviteSheet(pending: ["ada@example.com"])
        // New Message is a page now: its To: field's label and its suggestions' note.
        let to = HomeRecipientField(frame: NSRect(x: 0, y: 0, width: 480, height: 44))
        to.suggestions.show([], empty: "No teammates yet.")
        for root in [invite.view, to, to.suggestions] {
            scope.root(root)
            for label in Self.labels(in: root) {
                #expect(Self.isThemeInk(label.textColor, scope), "\(label.stringValue)")
            }
        }
    }

    @Test func buttonsAndPickersDrawTheThemeBezel() throws {
        let scope = try Self.purpleRoom()
        let settings = HomeChiefSettingsView(muxHome: FileManager.default.temporaryDirectory, source: UnreachableEngine())
        let restart = TerminalRestartButton()
        let placeholder = RemoteTerminalPlaceholderView(frame: .zero)
        let dialog = CmuxDialogView(spec: CmuxDialogSpec(title: "Move Tab", fields: [
            .choice(id: "window", label: nil, options: [.init(label: "Window A", value: "a")], selected: "a"),
        ], buttons: [.ok()]))
        let invite = HomeInviteSheet(pending: [])
        let views: [NSView] = [settings, restart, placeholder, dialog, invite.view]
        for view in views { scope.root(view) }

        // The sheets' factory-made buttons keep the system's automatic style, so they are named.
        let found = views.flatMap(Self.pushButtons(in:))
        // The Chief settings' Harness, Model, Effort and Speed pickers and its Reactions' Can Wake picker
        // (a416); its other buttons are links and disclosures.
        #expect(Self.pushButtons(in: settings).count == 5)
        #expect(found.count >= 4)
        let buttons = found + [invite.cancelButton]
        let fill = scope.perform { Palette.selectionFill }
        for button in buttons {
            let bezel = try #require(button.bezelColor, "\(button.title)")
            #expect(Self.same(bezel, fill), "\(button.title)")
        }
    }

    @Test func remoteBrowserNotesDrawInTheTheme() throws {
        let scope = try Self.purpleRoom()
        let state = MachineBrowserStateView(frame: .zero)
        state.show(.starting("Starting the browser"), queued: URL(string: "https://example.com"))
        let content = RemoteBrowserContentView(frame: .zero)
        content.showFailure("The page could not load")
        for view in [state, content] as [NSView] { scope.root(view) }

        let labels = Self.labels(in: state) + Self.labels(in: content)
        #expect(labels.count >= 3)
        for label in labels {
            #expect(Self.isThemeInk(label.textColor, scope), "\(label.stringValue)")
        }
    }

    // MARK: Helpers

    /// Every bordered push button and pop-up under `view`, `view` included.
    static func pushButtons(in view: NSView) -> [NSButton] {
        var found: [NSButton] = []
        if let button = view as? NSButton, button.isBordered, button.bezelStyle == .push { found.append(button) }
        for subview in view.subviews { found += pushButtons(in: subview) }
        return found
    }

    /// Every read-only text field under `view`.
    static func labels(in view: NSView) -> [any ShownText] {
        var found: [any ShownText] = []
        if let label = view as? ChromeLabel { found.append(label) }
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
    func set(_ fields: [String: String?]) async throws(HomeChiefEngineError) -> HomeChiefSnapshot { throw .localUnreachable }
}
