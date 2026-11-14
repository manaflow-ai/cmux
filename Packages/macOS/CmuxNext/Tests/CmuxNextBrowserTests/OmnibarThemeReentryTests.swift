import AppKit
@testable import CmuxNextBrowser
import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// https://github.com/manaflow-ai/cmux/issues/42436: the omnibar's URL and its page-info icon
/// kept an earlier theme's ink. The browser chrome leaves the window when its tab moves to another
/// pane or window, or while an agent drives it off screen, and a theme repaint reaches only views
/// in a window. Back in one, the bar's pill repainted itself (`OmnibarPillView.viewDidMoveToWindow`),
/// but the field and the chip recolored only on an appearance change, which a dark-to-dark theme
/// switch is not. Here the bar leaves a real window, the theme changes, and the bar comes back: its
/// text and icon must be the current theme's.
@MainActor
@Suite(.serialized, .closesItsWindows)
struct OmnibarThemeReentryTests {
    /// Both dark, so the switch is no appearance change. The first theme's ink is dim; the second's is bright.
    static let dimDark = ThemeInput(background: ThemeRGB(r: 0x1E, g: 0x1E, b: 0x1E), foreground: ThemeRGB(r: 0x50, g: 0x50, b: 0x50),
                                    backgroundOpacity: 1, backgroundBlur: 0)
    static let brightDark = ThemeInput(background: ThemeRGB(r: 0x18, g: 0x18, b: 0x20), foreground: ThemeRGB(r: 0xF2, g: 0xF2, b: 0xF2),
                                       backgroundOpacity: 1, backgroundBlur: 0)

    private struct Fixture {
        let window: NSWindow
        /// The workspace's scope: the window draws in it, as a main window does.
        let scope: ThemeScope
        let content: NSView
        /// The pane's browser chrome stand-in: the view that leaves the window and comes back.
        let chrome: NSView
        let bar: AddressBarView
    }

    private func fixture(url: String, security: BrowserSecurityState) throws -> Fixture {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let scope = ThemeScope(level: .workspace)
        scope.adopt(window)
        let content = try #require(window.contentView)
        // The chrome keeps one appearance in and out of the window, as the browser chrome in a
        // dark workspace does: leaving and coming back is then no appearance change.
        let chrome = NSView(frame: NSRect(x: 0, y: 0, width: 620, height: 80))
        chrome.appearance = NSAppearance(named: .darkAqua)
        let bar = AddressBarView(suggestionEngine: OmniboxSuggestionEngine())
        bar.translatesAutoresizingMaskIntoConstraints = false
        chrome.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: chrome.leadingAnchor, constant: 10),
            bar.trailingAnchor.constraint(equalTo: chrome.trailingAnchor, constant: -10),
            bar.topAnchor.constraint(equalTo: chrome.topAnchor, constant: 20),
        ])
        content.addSubview(chrome)
        bar.update(url: URL(string: url), security: security)
        bar.setBookmarkStar(.off)
        content.layoutSubtreeIfNeeded()
        return Fixture(window: window, scope: scope, content: content, chrome: chrome, bar: bar)
    }

    private struct Ink: Equatable, CustomStringConvertible {
        let rgba: [Int]
        init?(_ color: NSColor?) {
            guard let c = color?.usingColorSpace(.sRGB) else { return nil }
            rgba = [c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent].map { Int(($0 * 255).rounded()) }
        }
        var description: String { "rgba\(rgba)" }
    }

    /// The resting field's host and path ink (an http address keeps its `http://`, drawn as the
    /// path is), and the chip icon's and label's.
    private func shownInk(_ bar: AddressBarView, url: String) throws -> (host: Ink?, path: Ink?, icon: Ink?, label: Ink?) {
        let value = bar.field.attributedStringValue
        let host = try #require(BrowserURLDisplay.hostRange(in: value.string, for: URL(string: url)), "no host in \(value.string)")
        let hostInk = value.attribute(.foregroundColor, at: host.location, effectiveRange: nil) as? NSColor
        let path = value.attribute(.foregroundColor, at: value.length - 1, effectiveRange: nil) as? NSColor
        let icon = bar.chip.subviews.compactMap { $0 as? NSImageView }.first?.contentTintColor
        let label = bar.chip.subviews.compactMap { $0 as? ChromeLabel }.first?.textColor
        return (Ink(hostInk), Ink(path), Ink(icon), Ink(label))
    }

    /// The ink the bar's theme gives its text now.
    private func themeInk(_ bar: AddressBarView) -> (primary: Ink?, secondary: Ink?) {
        bar.performWithTheme { (Ink(OmnibarStyle.textPrimary), Ink(OmnibarStyle.textSecondary)) }
    }

    @Test(arguments: [("https://github.com/manaflow-ai/cmux/pull/42206", BrowserSecurityState.secure),
                      ("http://example.com/some/path", BrowserSecurityState.insecure)])
    func aThemeChangeWhileTheBarIsOutOfTheWindowRecolorsItOnReturn(url: String, security: BrowserSecurityState) throws {
        let original = ThemeScope.app.store.input
        defer { _ = ThemeScope.app.store.apply(original) }
        _ = ThemeScope.app.store.apply(Self.dimDark)

        let f = try fixture(url: url, security: security)
        defer { f.window.close() }
        let before = themeInk(f.bar)
        let shownBefore = try shownInk(f.bar, url: url)
        #expect(shownBefore.host == before.primary && shownBefore.path == before.secondary, "the bar does not start in its theme")

        // The pane shows another tab: the browser chrome leaves the window, and the theme changes meanwhile.
        f.chrome.removeFromSuperview()
        _ = ThemeScope.app.store.apply(Self.brightDark)
        f.content.addSubview(f.chrome)
        f.content.layoutSubtreeIfNeeded()

        let now = themeInk(f.bar)
        #expect(now.primary != before.primary, "the second theme's text is not another color")
        let shown = try shownInk(f.bar, url: url)
        #expect(shown.host == now.primary, "the host keeps the previous theme's ink: \(String(describing: shown.host)), theme \(String(describing: now.primary))")
        #expect(shown.path == now.secondary, "the path keeps the previous theme's ink: \(String(describing: shown.path)), theme \(String(describing: now.secondary))")
        #expect(shown.icon == now.primary, "the page-info icon keeps the previous theme's ink: \(String(describing: shown.icon)), theme \(String(describing: now.primary))")
        if security == .insecure {
            // Plain http: the "Not secure" label is drawn in the same ink as the icon.
            #expect(shown.label != nil && shown.label == shown.icon, "the chip's label and icon differ: \(String(describing: shown.label)) vs \(String(describing: shown.icon))")
        }
    }
}
