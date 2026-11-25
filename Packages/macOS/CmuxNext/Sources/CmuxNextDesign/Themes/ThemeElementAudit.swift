public import AppKit
public import CmuxNextDesignTokens

/// Every chrome element's ink on every ground it is drawn on, in one theme, read from the same
/// ``Palette`` colors the elements draw with (user 2026-11-03: "we need to make sure every single
/// theme, all the UI elements are colored properly").
///
/// The All Themes playground (Debug menu) shows the samples of every bundled theme, and
/// `EveryThemeElementContrastTests` fails on any sample that does not pass: an ink under its WCAG 2
/// minimum, or a color that follows the system's light or dark appearance instead of the theme.
///
/// ```swift
/// let scope = ThemeScope(level: .workspace)
/// scope.setOverride(ThemeSpec("Nord"), input: input, animated: false)
/// let failures = ThemeElementAudit(scope: scope).failures
/// ```
@MainActor public struct ThemeElementAudit {
    /// Every sample, in playground order.
    public let samples: [ThemeElementSample]

    /// The samples that do not pass (``ThemeElementSample/passes``).
    public var failures: [ThemeElementSample] { samples.filter { !$0.passes } }

    /// Reads the samples of `scope`'s theme.
    /// - Parameter scope: The theme scope whose ``Palette`` colors the elements draw with.
    public init(scope: ThemeScope) {
        let isDark = scope.tokens.isDark
        let colors = scope.perform { AuditColors() }
        let window = Resolved(colors.window, isDark: isDark)
        func over(_ fill: NSColor, _ base: Resolved) -> Resolved { Resolved(fill, isDark: isDark, over: base) }
        let rows: [(ThemeElementGround, Resolved)] = [
            (.window, window),
            (.hoveredRow, over(colors.hover, window)),
            (.selectedRow, over(colors.selection, window)),
            (.pressedRow, over(colors.pressed, window)),
        ]
        let selected = [rows[0], rows[2]]
        // Popovers, the palette and cards are glass (`CardMaterial`): the tint over the worst desktop for the theme.
        // glass-opaque-allow: measures the card fill OverlaySurfaceView draws (its cardMaterial); the audit draws nothing.
        let card = CardMaterial(scope.tokens, lift: ChromeTunables.opaqueOverlayLift.value, minimumOpacity: ChromeTunables.cardOpacity.value)
        let popup = Resolved(card.tint.composited(over: isDark ? .white : .black))
        let text = ThemeTokens.minimumTextContrast, mark = ThemeTokens.minimumMarkContrast
        var samples: [ThemeElementSample] = []
        func add(_ element: ThemeElement, _ ink: NSColor, on grounds: [(ThemeElementGround, Resolved)], minimum: Double) {
            for (name, ground) in grounds {
                let resolved = over(ink, ground)
                samples.append(ThemeElementSample(
                    element: element, ground: name, ink: resolved.color, surface: ground.color, minimum: minimum,
                    followsSystemAppearance: resolved.followsSystem || ground.followsSystem))
            }
        }
        add(.title, colors.textPrimary, on: rows, minimum: text)
        add(.detail, colors.textSecondary, on: rows, minimum: text)
        add(.hint, colors.textTertiary, on: [rows[0]], minimum: mark)
        add(.dotUnread, colors.statusUnread, on: selected, minimum: mark)
        add(.dotAttention, colors.statusAttention, on: selected, minimum: mark)
        add(.dotError, colors.statusError, on: selected, minimum: mark)
        add(.unreadBadge, colors.notification, on: selected, minimum: mark)
        add(.spinner, colors.spinner, on: selected, minimum: mark)
        add(.statusAttention, colors.attention, on: [rows[0]], minimum: mark)
        add(.statusError, colors.danger, on: [rows[0]], minimum: mark)
        add(.statusSuccess, colors.success, on: [rows[0]], minimum: mark)
        add(.litGlyph, colors.litGlyph, on: [rows[0]], minimum: mark)
        add(.popoverText, colors.textPrimary, on: [(.popover, popup)], minimum: text)
        add(.popoverDetail, colors.textSecondary, on: [(.popover, popup)], minimum: text)
        add(.highlightedRow, colors.textPrimary, on: [(.highlightedRow, over(colors.menuHighlight, popup))],
            minimum: text)
        add(.accentLabel, colors.onAccent, on: [(.accentButton, Resolved(colors.accentFill, isDark: isDark))], minimum: text)
        add(.updateLabel, colors.highlightText, on: [(.updateButton, Resolved(colors.highlight, isDark: isDark))],
            minimum: text)
        self.samples = samples
    }
}

/// The ``Palette`` colors the audit reads, taken inside the scope (`ThemeScope.perform`).
@MainActor private struct AuditColors {
    let window = Palette.windowBackground, hover = Palette.hoverFill, selection = Palette.selectionFill
    let pressed = Palette.pressedFill, menuHighlight = Palette.menuHighlight
    let textPrimary = Palette.textPrimary, textSecondary = Palette.textSecondary, textTertiary = Palette.textTertiary
    let statusUnread = Palette.statusUnread, statusAttention = Palette.statusAttention, statusError = Palette.statusError
    let notification = Palette.notificationBlue
    let spinner = NSColor(cgColor: StatusIndicatorLayer.Colors.current(loading: nil).color(for: .spinner)) ?? .clear
    let attention = Palette.attention, danger = Palette.danger, success = Palette.success, litGlyph = Palette.litGlyph
    let accentFill = Palette.accentFill, onAccent = Palette.onAccent
    let highlight = Palette.highlight, highlightText = Palette.highlightText
}

/// A color as the theme's own appearance draws it (opaque, over `base` when it has alpha), and
/// whether the other appearance would draw it differently.
@MainActor private struct Resolved {
    let color: ThemeRGB
    let followsSystem: Bool

    /// A color the theme computes itself (never a system color).
    init(_ color: ThemeRGB) {
        self.color = color.withAlpha(1)
        followsSystem = false
    }

    init(_ color: NSColor, isDark: Bool, over base: Resolved? = nil) {
        let own = Self.rgb(color, dark: isDark), other = Self.rgb(color, dark: !isDark)
        let ground = base?.color ?? .black
        self.color = own.composited(over: ground).withAlpha(1)
        followsSystem = !Self.same(own, other) || base?.followsSystem == true
    }

    private static func rgb(_ color: NSColor, dark: Bool) -> ThemeRGB {
        var result = ThemeRGB.black
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            let srgb = color.usingColorSpace(.sRGB) ?? .black
            result = ThemeRGB(red: srgb.redComponent, green: srgb.greenComponent, blue: srgb.blueComponent,
                              alpha: srgb.alphaComponent)
        }
        return result
    }

    private static func same(_ a: ThemeRGB, _ b: ThemeRGB) -> Bool {
        abs(a.red - b.red) < 0.004 && abs(a.green - b.green) < 0.004 && abs(a.blue - b.blue) < 0.004
            && abs(a.alpha - b.alpha) < 0.004
    }
}
