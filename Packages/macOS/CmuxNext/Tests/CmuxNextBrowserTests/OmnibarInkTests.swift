import AppKit
@testable import CmuxNextBrowser
@testable import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// https://github.com/manaflow-ai/cmux/issues/50986: "after i click on the star for favorite, it changes into white but
/// isn't white by default ... it should check what the color of the omnibar is and make it readable under light and
/// dark colors." A real address bar in a real window: every mark on it (the host, the path, the placeholder, the
/// site-info icon, the star hollow and filled, the profile badge) takes the bar's ink (`OmnibarInk`), which reads at
/// 4.5:1 on every ground the bar shows, the same color in every state, and the shown theme's on entering a window.
@MainActor
@Suite(.serialized, .closesItsWindows)
struct OmnibarInkTests {
    /// A dark theme whose own secondary tone is muted to 4.5:1 over the window, so over the bar's lift and hover it
    /// reads under 4.5:1: the hollow star, the path and the placeholder drew it.
    static let softDark = ThemeInput(background: ThemeRGB(r: 0x20, g: 0x22, b: 0x26), foreground: ThemeRGB(r: 0xB8, g: 0xB8, b: 0xB8),
                                     backgroundOpacity: 1, backgroundBlur: 0)
    static let light = ThemeInput(background: ThemeRGB(r: 0xFA, g: 0xFA, b: 0xFA), foreground: ThemeRGB(r: 0x1E, g: 0x1E, b: 0x20),
                                  backgroundOpacity: 1, backgroundBlur: 0)
    static let brightDark = ThemeInput(background: ThemeRGB(r: 0x18, g: 0x18, b: 0x20), foreground: ThemeRGB(r: 0xF2, g: 0xF2, b: 0xF2),
                                       backgroundOpacity: 1, backgroundBlur: 0)

    private struct Fixture {
        let window: NSWindow
        let content: NSView
        let chrome: NSView
        let bar: AddressBarView
    }

    /// A bar in a chrome view; in `window`'s content when `inWindow`.
    private func fixture(window: NSWindow, url: String, inWindow: Bool = true, dark: Bool = true) throws -> Fixture {
        let content = try #require(window.contentView)
        let chrome = NSView(frame: NSRect(x: 0, y: 0, width: 620, height: 80))
        chrome.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let bar = AddressBarView(suggestionEngine: OmniboxSuggestionEngine())
        bar.translatesAutoresizingMaskIntoConstraints = false
        chrome.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: chrome.leadingAnchor, constant: 10),
            bar.trailingAnchor.constraint(equalTo: chrome.trailingAnchor, constant: -10),
            bar.topAnchor.constraint(equalTo: chrome.topAnchor, constant: 20),
        ])
        bar.update(url: URL(string: url), security: .secure)
        bar.setBookmarkStar(.off)
        bar.setProfileBadge(BrowserProfileBadge(monogram: "D", color: nil, name: "Default"))
        if inWindow {
            content.addSubview(chrome)
            settle(window)
        }
        return Fixture(window: window, content: content, chrome: chrome, bar: bar)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    /// Lays out and draws the window, so `updateLayer` tints run as on screen.
    private func settle(_ window: NSWindow) {
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }

    private func rgb(_ color: NSColor?) throws -> ThemeRGB {
        let c = try #require(color?.usingColorSpace(.sRGB))
        return ThemeRGB(red: Double(c.redComponent), green: Double(c.greenComponent), blue: Double(c.blueComponent), alpha: Double(c.alphaComponent))
    }

    private func same(_ a: NSColor?, _ b: NSColor?) throws -> Bool {
        let x = try rgb(a), y = try rgb(b)
        return [x.red - y.red, x.green - y.green, x.blue - y.blue, x.alpha - y.alpha].allSatisfy { abs($0) < 0.002 }
    }

    private func chipIcon(_ bar: AddressBarView) -> NSColor? { bar.chip.subviews.compactMap { $0 as? NSImageView }.first?.contentTintColor }

    private func hostInk(_ bar: AddressBarView, url: String) throws -> NSColor? {
        let value = bar.field.attributedStringValue
        let host = try #require(BrowserURLDisplay.hostRange(in: value.string, for: URL(string: url)))
        return value.attribute(.foregroundColor, at: host.location, effectiveRange: nil) as? NSColor
    }

    private func placeholderInk(_ bar: AddressBarView) -> NSColor? {
        guard let placeholder = bar.field.placeholderAttributedString, placeholder.length > 0 else { return nil }
        return placeholder.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
    }

    /// The hollow star is the color the filled one is: clicking it changes its shape, not its ink.
    @Test func theStarIsOneInkHollowOrFilled() throws {
        let original = ThemeScope.app.store.input
        defer { _ = ThemeScope.app.store.apply(original) }
        _ = ThemeScope.app.store.apply(Self.softDark)
        let window = makeWindow()
        defer { window.close() }
        let f = try fixture(window: window, url: "https://github.com/manaflow-ai/cmux")

        let hollow = f.bar.starButton.shownTint
        f.bar.setBookmarkStar(.on)
        settle(window)
        let filled = f.bar.starButton.shownTint
        #expect(try same(hollow, filled), "the star changes color when bookmarked: \(String(describing: hollow)) then \(String(describing: filled))")
        #expect(try same(hollow, chipIcon(f.bar)), "the star and the site-info icon differ")
    }

    /// Every mark reads at 4.5:1 on each ground the bar shows (rest, hover, editing card), in a theme whose own
    /// secondary tone does not.
    @Test(arguments: [false, true])
    func everyMarkReadsOnTheBar(light: Bool) throws {
        let original = ThemeScope.app.store.input
        defer { _ = ThemeScope.app.store.apply(original) }
        _ = ThemeScope.app.store.apply(light ? Self.light : Self.softDark)
        let window = makeWindow()
        defer { window.close() }
        let url = "https://github.com/manaflow-ai/cmux"
        let f = try fixture(window: window, url: url, dark: !light)

        let (grounds, themeSecondary) = f.bar.performWithTheme {
            (Palette.addressBar.inkGrounds(.flat(coverage: 0)), (ThemeContext.active ?? ThemeScope.app.tokens).textSecondary)
        }
        if !light {
            // The theme's own secondary tone misses on the bar: the check below guards a real gap.
            #expect(OmnibarInk.worstContrast(themeSecondary, over: grounds) < ThemeTokens.minimumTextContrast)
        }
        let marks: [(String, NSColor?, [ThemeRGB])] = [
            ("host", try hostInk(f.bar, url: url), grounds),
            ("site-info icon", chipIcon(f.bar), grounds),
            ("star", f.bar.starButton.shownTint, grounds),
            ("placeholder", placeholderInk(f.bar), grounds),
        ]
        for (name, color, under) in marks {
            let contrast = OmnibarInk.worstContrast(try rgb(color), over: under)
            #expect(contrast >= ThemeTokens.minimumTextContrast - 0.01, "\(name) reads \(contrast):1 on the bar")
        }
    }

    /// A star made outside a window, in the app's light theme, takes the dark workspace's ink on entering its window,
    /// with no click: before, only a state change redrew it.
    @Test func theStarTakesTheShownThemesInkOnEnteringAWindow() throws {
        let original = ThemeScope.app.store.input
        defer { _ = ThemeScope.app.store.apply(original) }
        _ = ThemeScope.app.store.apply(Self.light)
        let window = makeWindow()
        defer { window.close() }
        let workspace = ThemeScope(level: .workspace)
        workspace.setOverride(try #require(ThemeSpec("Ink dark")), input: Self.brightDark, animated: false)
        workspace.adopt(window)

        let f = try fixture(window: window, url: "https://example.com", inWindow: false)
        f.bar.starButton.updateLayer()
        let outside = f.bar.starButton.shownTint
        f.content.addSubview(f.chrome)
        settle(window)
        let inside = f.bar.performWithTheme { OmnibarStyle.iconInk }
        #expect(try !same(outside, inside), "the app's ink is not another color than the workspace's")
        #expect(try same(f.bar.starButton.shownTint, inside), "the star keeps the app theme's ink in the dark workspace")
    }
}
