import AppKit
import CmuxNextTestSupport
import CmuxTheme
@testable import CmuxNextDesign
import Testing
import CmuxNextDesignTokens

/// cx-ujp: a cmux dialog in a light theme drew low-contrast body lines. Its labels took their
/// ink once, while the dialog was built outside any window, so a dialog shown in a light
/// window (or one whose theme turned light while it showed) kept another theme's text over the
/// light surface. The labels must re-read their ink in the scope they draw in, in an inactive
/// (never key) window too, and the surface must stay a light card, not a grey slab. These
/// check the solid card a dialog draws under Reduce Transparency; on glass the tint carries it.
@MainActor @Suite(.serialized, .closesItsWindows) struct CmuxDialogLightContrastTests {
    private static let light = ThemeInput(background: ThemeRGB(hex: 0xFFFFFF), foreground: ThemeRGB(hex: 0x1D1D1F))
    private static let dark = ThemeInput(background: ThemeRGB(hex: 0x1E1E1E), foreground: ThemeRGB(hex: 0xE6E6E6))

    /// Pins the solid popup surface for one test; returns the setting to restore.
    private static func pinOpaque() -> Bool? {
        let pinned = ReduceTransparency.shared.override
        ReduceTransparency.shared.override = true
        return pinned
    }

    private static func scope(_ input: ThemeInput, _ name: String) throws -> ThemeScope {
        let scope = ThemeScope(level: .room)
        scope.setOverride(ThemeSpec(name), input: input, animated: false)
        return scope
    }

    /// An inactive window rooted in `scope`.
    private static func window(in scope: ThemeScope) throws -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 420), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        scope.root(try #require(window.contentView))
        return window
    }

    private static func dialog() -> CmuxDialogView {
        CmuxDialogView(spec: CmuxDialogSpec(
            title: "Export Your Passwords",
            lines: ["Open the Passwords app.", "Choose File > Export All Passwords and save the CSV file."], origin: "cmux",
            buttons: [CmuxDialogButton(id: "delete", title: "Delete", role: .destructive, key: "d"), .cancel(), .ok("Choose File")]))
    }

    private static func show(_ dialog: CmuxDialogView, in window: NSWindow) throws {
        let root = try #require(window.contentView)
        dialog.removeFromSuperview()
        root.addSubview(dialog)
        root.layoutSubtreeIfNeeded()
    }

    @Test func aDialogMovedIntoALightWindowDrawsReadableText() throws {
        let pinned = Self.pinOpaque()
        defer { ReduceTransparency.shared.override = pinned }
        let darkWindow = try Self.window(in: try Self.scope(Self.dark, "Contrast Dark"))
        let lightScope = try Self.scope(Self.light, "Contrast Light")
        let lightWindow = try Self.window(in: lightScope)
        defer { darkWindow.close(); lightWindow.close() }
        let dialog = Self.dialog()
        try Self.show(dialog, in: darkWindow)
        try Self.show(dialog, in: lightWindow)
        #expect(!lightWindow.isKeyWindow)
        try Self.expectReadable(dialog, in: lightScope)
    }

    /// The mirror case: whichever theme the app scope has when the dialog is built, one of the
    /// two moves lands it in the other one.
    @Test func aDialogMovedIntoADarkWindowDrawsReadableText() throws {
        let pinned = Self.pinOpaque()
        defer { ReduceTransparency.shared.override = pinned }
        let lightWindow = try Self.window(in: try Self.scope(Self.light, "Contrast Light First"))
        let darkScope = try Self.scope(Self.dark, "Contrast Dark Second")
        let darkWindow = try Self.window(in: darkScope)
        defer { lightWindow.close(); darkWindow.close() }
        let dialog = Self.dialog()
        try Self.show(dialog, in: lightWindow)
        try Self.show(dialog, in: darkWindow)
        try Self.expectReadable(dialog, in: darkScope)
    }

    @Test func aDialogWhoseThemeTurnsLightDrawsReadableText() throws {
        let pinned = Self.pinOpaque()
        defer { ReduceTransparency.shared.override = pinned }
        let scope = try Self.scope(Self.dark, "Contrast Switch")
        let window = try Self.window(in: scope)
        defer { window.close() }
        let dialog = Self.dialog()
        try Self.show(dialog, in: window)
        scope.setOverride(ThemeSpec("Contrast Switch Light"), input: Self.light, animated: false)
        #expect(!window.isKeyWindow)
        try Self.expectReadable(dialog, in: scope)
    }

    @Test func aDarkDialogDrawsItsWindowsInk() throws {
        let pinned = Self.pinOpaque()
        defer { ReduceTransparency.shared.override = pinned }
        let scope = try Self.scope(Self.dark, "Contrast Dark Only")
        let window = try Self.window(in: scope)
        defer { window.close() }
        let dialog = Self.dialog()
        try Self.show(dialog, in: window)
        let surface = try Self.surfaceFill(dialog)
        #expect(Self.distance(surface, scope.perform { Palette.popupSurface }) < 0.01)
        for label in Self.labels(in: dialog) {
            let color = try #require(label.textColor)
            let inks = scope.perform { [Palette.textPrimary, Palette.textSecondary] }
            #expect(inks.contains { Self.distance(color, $0) < 0.01 }, "\(label.stringValue)")
        }
    }

    /// The same contract over the glass card (the veil over the scrimmed window, as a dialog shows
    /// without Reduce Transparency), for both destructive variants, in each state, light and dark,
    /// for a theme with its own accent too.
    @Test(arguments: [false, true])
    func everyDialogButtonInkReadsOnTheGlassCard(filledDestructive: Bool) throws {
        let accented = ThemeInput(background: ThemeRGB(hex: 0x1F2430), foreground: ThemeRGB(hex: 0xCBCCC6))
        for input in [Self.light, Self.dark, accented] {
            let tokens = ThemeTokens.derive(from: input)
            for role in [CmuxDialogButton.Role.default, .destructive, .cancel, .normal] {
                for state in CmuxDialogButtonLook.State.allCases {
                    let look = CmuxDialogButtonLook(role: role, tokens: tokens, state: state, filledDestructive: filledDestructive)
                    #expect(look.surfaces.count == CmuxDialogButtonLook.cardSurfaces(tokens).count)
                    for surface in look.surfaces {
                        #expect(look.title.contrast(with: surface) >= 4.5, "\(role) \(state) title: \(look.title.contrast(with: surface)):1")
                        #expect(look.keyHint.contrast(with: surface) >= 4.5, "\(role) \(state) hint: \(look.keyHint.contrast(with: surface)):1")
                    }
                }
            }
            // A filled destructive button and the default one are solid: what shows through the glass
            // cannot lower their contrast.
            #expect(CmuxDialogButtonLook(role: .default, tokens: tokens).fill.alpha == 1)
            #expect(CmuxDialogButtonLook(role: .destructive, tokens: tokens, filledDestructive: true).fill.alpha == 1)
        }
    }

    /// The keyboard focus shows on a solid default button too: the ring sits just outside the fill,
    /// in its window, and nothing clips it (a ring drawn inside a solid fill, or clipped away, left
    /// the focused button looking like any other).
    @Test func theFocusedButtonDrawsAnUnclippedRingOutsideItsFill() throws {
        let scope = try Self.scope(Self.dark, "Focus Ring")
        let window = try Self.window(in: scope)
        defer { window.close() }
        let dialog = Self.dialog()
        try Self.show(dialog, in: window)
        let save = try #require(dialog.buttonViews.first { $0.button.role == .default })
        #expect(window.makeFirstResponder(save))
        save.layoutSubtreeIfNeeded()
        let layer = try #require(save.layer)
        #expect(!save.clipsToBounds && !layer.masksToBounds, "the ring is clipped away")
        // The ring is the bordered layer outside the button (the gap line on a solid fill is inside).
        let rings = (layer.sublayers ?? []).filter { !$0.isHidden && $0.borderWidth > 0 }
        let ring = try #require(rings.max { $0.frame.width < $1.frame.width }, "a focused button draws no ring")
        #expect(ring.frame.width > layer.bounds.width && ring.frame.height > layer.bounds.height, "the ring is inside the fill")
        #expect(window.makeFirstResponder(nil))
        #expect((layer.sublayers ?? []).allSatisfy { $0.isHidden || $0.borderWidth == 0 }, "an unfocused button keeps its ring")
    }

    /// User, 2026-10-29: a focused button's ring overlapped the controls beside it. Dialog buttons sit
    /// `Metrics.space2` apart, and the ring reached 4 pt past its button. With each button of a
    /// three-button dialog focused in turn, its ring stays clear of every other button.
    @Test func aFocusedButtonsRingNeverReachesTheNextButton() throws {
        let scope = try Self.scope(Self.dark, "Focus Ring Neighbors")
        let window = try Self.window(in: scope)
        defer { window.close() }
        let dialog = Self.dialog()
        try Self.show(dialog, in: window)
        #expect(dialog.buttonViews.count == 3)
        for focused in dialog.buttonViews {
            #expect(window.makeFirstResponder(focused))
            dialog.layoutSubtreeIfNeeded()
            let layer = try #require(focused.layer)
            let ring = try #require((layer.sublayers ?? []).first { !$0.isHidden && $0.frame.width > layer.bounds.width },
                                    "\(focused.button.title): no ring outside the button")
            // At least a point clear: a ring that ends on the neighbor's edge draws against it.
            let ringInDialog = focused.convert(ring.frame, to: dialog).insetBy(dx: -1, dy: -1)
            for other in dialog.buttonViews where other !== focused {
                let otherInDialog = other.convert(other.bounds, to: dialog)
                #expect(!ringInDialog.intersects(otherInDialog),
                        "\(focused.button.title)'s ring \(ringInDialog) overlaps \(other.button.title) \(otherInDialog)")
            }
        }
    }

    /// Visual review of #27638: a focused solid button drew its focus band inside its bounds, so its
    /// fill looked 3 px smaller on every side than its unfocused neighbors' and its edges no longer
    /// lined up with theirs. Every focus layer of a focused button sits outside its fill.
    @Test func aFocusedSolidButtonKeepsItsFullFill() throws {
        let scope = try Self.scope(Self.dark, "Focus Full Fill")
        let window = try Self.window(in: scope)
        defer { window.close() }
        let dialog = Self.dialog()
        try Self.show(dialog, in: window)
        let save = try #require(dialog.buttonViews.first { $0.button.role == .default })
        #expect(window.makeFirstResponder(save))
        save.layoutSubtreeIfNeeded()
        let layer = try #require(save.layer)
        let shown = (layer.sublayers ?? []).filter { !$0.isHidden && $0.borderWidth > 0 }
        #expect(shown.count >= 2, "a focused solid button draws its gap and its ring")
        for band in shown {
            // A border is drawn inside its layer's frame: it is outside the fill only if the frame's
            // inner edge (frame inset by the border) still contains the button's bounds.
            let inner = band.frame.insetBy(dx: band.borderWidth, dy: band.borderWidth)
            #expect(inner.contains(layer.bounds), "a focus band \(band.frame) (\(band.borderWidth) pt) covers the fill \(layer.bounds)")
        }
    }

    /// Visual review of #27638 (real-app capture at c45470c72c22): the light-mode focus ring read
    /// 2.73:1 on the dialog card, under WCAG's 3:1 for a focus indicator, and on a gray Cancel it is
    /// the only sign of focus. The ring is fit to 3:1 on both card surfaces, light and dark.
    @Test(arguments: [false, true])
    func theFocusRingReadsAtThreeToOneOnTheCard(isDark: Bool) throws {
        let tokens = ThemeTokens.derive(from: isDark ? Self.dark : Self.light)
        let look = CmuxDialogButtonLook(role: .cancel, tokens: tokens)
        // The real glass card shows little of its veil: on a light theme it measured rgb(223,223,223),
        // the scrimmed window itself (real-app capture at 1dcfb3faa718, where a ring fit only to the
        // veil estimate still read 2.66:1). The ring reads on that too.
        let scrimmedWindow = tokens.scrim.composited(over: tokens.windowBackground.withAlpha(1))
        for surface in CmuxDialogButtonLook.cardSurfaces(tokens) + [scrimmedWindow] {
            let ring = look.focusRing.composited(over: surface)
            #expect(ring.contrast(with: surface) >= 3, "ring \(ring.contrast(with: surface)):1 on the card")
        }
    }

    // MARK: Checks

    /// Every label is at least 4.5:1 on the resolved surface, and the surface is the scope's popup
    /// surface, at least as light as the page.
    private static func expectReadable(_ dialog: CmuxDialogView, in scope: ThemeScope) throws {
        let surface = try surfaceFill(dialog)
        let page = scope.perform { Palette.windowBackground }
        #expect(distance(surface, scope.perform { Palette.popupSurface }) < 0.01, "the surface is the theme's popup surface")
        #expect(luminance(surface) >= luminance(page) - 0.001, "the surface is no darker than the page")
        let labels = labels(in: dialog)
        #expect(labels.count >= 4)
        for label in labels {
            let ink = try #require(label.textColor)
            #expect(contrast(ink, surface) >= 4.5, "\(label.stringValue): \(contrast(ink, surface)):1")
        }
        // Button titles and their key hints over their fill, itself over the surface: the destructive
        // title too (the theme's danger is fit only to 3:1; over the dialog glass it measured 2.1:1).
        for button in dialog.buttonViews {
            let fill = try #require(button.layer?.backgroundColor.flatMap(NSColor.init(cgColor:)))
            let title = button.attributedTitle
            let ink = try #require(title.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
            let under = composite(fill, over: surface)
            #expect(contrast(ink, under) >= 4.5, "\(button.button.title): \(contrast(ink, under)):1")
            let hint = try #require(title.attribute(.foregroundColor, at: title.length - 1, effectiveRange: nil) as? NSColor)
            #expect(contrast(hint, under) >= 4.5, "\(button.button.title)'s key hint: \(contrast(hint, under)):1")
        }
        // The default button (Return) stands out from Cancel: its fill and Cancel's differ at least 3:1
        // (WCAG's non-text contrast), not by the 3 to 4% of gray they did.
        let fills = try dialog.buttonViews.reduce(into: [CmuxDialogButton.Role: NSColor]()) { fills, button in
            fills[button.button.role] = composite(try #require(button.layer?.backgroundColor.flatMap(NSColor.init(cgColor:))), over: surface)
        }
        let primary = try #require(fills[.default]), cancel = try #require(fills[.cancel])
        #expect(contrast(primary, cancel) >= 3, "default vs cancel fill: \(contrast(primary, cancel)):1")
    }

    private static func composite(_ top: NSColor, over bottom: NSColor) -> NSColor {
        let (r, g, b, a) = rgb(top)
        let (br, bg, bb, _) = rgb(bottom)
        return NSColor(srgbRed: r * a + br * (1 - a), green: g * a + bg * (1 - a), blue: b * a + bb * (1 - a), alpha: 1)
    }

    private static func surfaceFill(_ dialog: CmuxDialogView) throws -> NSColor {
        let surface = try #require(dialog.surface)
        let fill = surface.subviews.lazy.compactMap { $0.layer?.backgroundColor }.first
        return try #require(fill.flatMap(NSColor.init(cgColor:)))
    }

    /// The dialog's text labels; a button's own title view is the button's (checked by `buttons`).
    private static func labels(in view: NSView) -> [any ShownText] {
        if view is NSButton { return [] }
        var found: [any ShownText] = []
        if let label = view as? ChromeLabel, !label.stringValue.isEmpty { found.append(label) }
        if let field = view as? NSTextField, !field.isEditable, !field.stringValue.isEmpty { found.append(field) }
        for subview in view.subviews { found += labels(in: subview) }
        return found
    }

    private static func rgb(_ color: NSColor) -> (CGFloat, CGFloat, CGFloat, CGFloat) {
        let c = color.usingColorSpace(.sRGB) ?? .black
        return (c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent)
    }

    private static func luminance(_ color: NSColor) -> CGFloat {
        let (r, g, b, _) = rgb(color)
        func lin(_ v: CGFloat) -> CGFloat { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    /// WCAG contrast of `ink` composited over the opaque `surface`.
    private static func contrast(_ ink: NSColor, _ surface: NSColor) -> CGFloat {
        let flat = composite(ink, over: surface)
        let (l1, l2) = (luminance(flat), luminance(surface))
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    private static func distance(_ lhs: NSColor, _ rhs: NSColor) -> CGFloat {
        let (a, b) = (rgb(lhs), rgb(rhs))
        return max(abs(a.0 - b.0), abs(a.1 - b.1), abs(a.2 - b.2), abs(a.3 - b.3))
    }
}
