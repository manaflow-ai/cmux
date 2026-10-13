public import Foundation

/// The one web theme (plans/cmux-next/windows.md, "One background token"):
/// the CSS custom properties every cmux web page reads, from the same
/// tokens as the native chrome. `--cmux-surface-background` is the page
/// background: the surface token in an opaque window, transparent over a
/// see-through window, where the window's one backdrop shows through.
///
/// Pages get ``bootstrapScript`` at document start (it defines
/// `window.cmuxTheme.apply(payload)` and makes `html` paint
/// `--cmux-surface-background` with `body` transparent) and
/// ``applyScript`` on load and on every theme change.
///
/// ```swift
/// webView.evaluateJavaScript(WebTheme(tokens).applyScript)
/// ```
public nonisolated struct WebTheme: Equatable, Sendable {
    /// `--cmux-*` name to CSS value.
    public let variables: [String: String]
    /// `dark` or `light`.
    public let colorScheme: String
    /// The macOS "Show scroll bars" setting as `overlay` or `legacy` (``SystemScrollers/pageValue``):
    /// `data-scrollers` on `<html>`, so pages with their own scrollers (Monaco, the diff and file
    /// tree libraries) show them at rest only for "Always".
    public let scrollers: String
    /// The terminal theme as hex (`type`, `background`, `foreground`, `palette` 0...15): pages
    /// color code from its ANSI palette (syntax-theme.ts), as the agent chat and Ghostty do.
    public let terminal: Terminal

    /// The terminal colors a page highlights code with: the scope's opaque background and
    /// readable foreground, and its ANSI palette as the theme names it (the page lifts each
    /// slot only as far as it needs to read).
    public nonisolated struct Terminal: Equatable, Sendable {
        public let type: String
        public let background: String
        public let foreground: String
        public let palette: [String: String]

        init(_ tokens: ThemeTokens) {
            type = tokens.isDark ? "dark" : "light"
            background = WebTheme.hex(tokens.surfaceBackground)
            foreground = WebTheme.hex(tokens.textPrimary)
            palette = Dictionary(uniqueKeysWithValues: tokens.ansi.prefix(16).enumerated().map { (String($0.offset), WebTheme.hex($0.element)) })
        }

        var json: [String: Any] { ["type": type, "background": background, "foreground": foreground, "palette": palette] }
    }

    /// - Parameter tokens: The theme tokens of the view's scope.
    /// - Parameter reduceTransparency: The user's Reduce Transparency setting.
    /// - Parameter surface: The surface the page is (agent chat, new tab
    ///   page): its background override (`appearance.surfaces`, R55)
    ///   replaces the page background. Nil: no override applies.
    /// - Parameter backgrounds: The per-surface overrides (the app's).
    /// - Parameter scrollers: `overlay` or `legacy`; nil reads the system setting.
    /// - Parameter app: The app theme the page's `--cmux-app-*` tokens come from: the store's
    ///   (`appearance.appTheme`) when it names one, else the scope's own (`tokens.app`).
    @MainActor
    public init(_ tokens: ThemeTokens, reduceTransparency: Bool = false, surface surfaceKind: SurfaceKind? = nil,
                backgrounds: SurfaceBackgrounds = ThemeScope.app.surfaceBackgrounds, scrollers: String? = nil,
                app: AppTheme? = nil) {
        let pageOpaque = WindowBackdrop.current(tokens, reduceTransparency: reduceTransparency).panesPaintBackground
        let surface = tokens.surfaceBackground
        let page = surfaceKind.flatMap { backgrounds.fill(for: $0, tokens: tokens) }
            ?? (pageOpaque ? surface.withAlpha(1) : surface.withAlpha(0))
        variables = [
            "--cmux-surface-background": Self.css(page),
            "--cmux-surface-token": Self.css(surface),
            // The page color made opaque (its own background over the theme's, if it has one),
            // for rings, pills and glyphs on fills that must hide what is under them.
            "--cmux-surface-solid": Self.css(surfaceKind.map {
                backgrounds.opaqueFill(for: $0, tokens: tokens, base: surface.withAlpha(1))
            } ?? surface.withAlpha(1)),
            "--cmux-elevated-background": Self.css(tokens.elevatedBackground),
            // The solid surface of menus, popovers and tooltips (`--surface-popup`), the same
            // opaque fill as native overlays (`Palette.popupSurface`).
            "--cmux-popup-surface": Self.css(tokens.opaqueOverlayFill(lift: ChromeTunables.opaqueOverlayLift.value)),
            "--cmux-text": Self.css(tokens.textPrimary),
            "--cmux-text-secondary": Self.css(tokens.textSecondary),
            "--cmux-text-tertiary": Self.css(tokens.textTertiary),
            "--cmux-separator": Borders.drawsLines ? Self.css(tokens.separator) : "transparent",
            "--cmux-hover": Self.css(tokens.hoverFill),
            "--cmux-selection": Self.css(tokens.selectionFill),
            // Selected text and the caret in the Ghostty config's colors (`selection-background`,
            // `cursor-color`); without a selection color, the accent tint pages always used.
            "--cmux-text-selection": tokens.terminalSelection.map(Self.css)
                ?? "color-mix(in srgb, var(--cmux-accent, CanvasText) 28%, transparent)",
            "--cmux-caret": Self.css(tokens.caret),
            // The accent and the glyphs on it (`ThemeTokens.accent`: the text color, or the
            // theme's own hue with appearance.accent).
            "--cmux-accent": Self.css(tokens.accent),
            "--cmux-on-accent": Self.css(tokens.onAccent),
            // The modal scrim (`Scrim`), the same as native dialogs'.
            "--cmux-scrim": Self.css(tokens.scrim),
        ].merging((app ?? ThemeStore.shared.appTheme ?? tokens.app).cssVariables) { own, _ in own }
        colorScheme = tokens.isDark ? "dark" : "light"
        self.scrollers = scrollers ?? SystemScrollers.pageValue
        terminal = Terminal(tokens)
    }

    /// The payload `window.cmuxTheme.apply` takes: `{variables, colorScheme, scrollers, terminal}`.
    public var payloadJSON: String {
        let object: [String: Any] = ["variables": variables, "colorScheme": colorScheme, "scrollers": scrollers,
                                     "terminal": terminal.json]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }

    /// Applies this theme to a page that ran ``bootstrapScript``.
    public var applyScript: String { "window.cmuxTheme && window.cmuxTheme.apply(\(payloadJSON));" }

    /// Defines `window.cmuxTheme` and the page background rule. Install it
    /// at document start in every cmux-owned web view.
    public static let bootstrapScript = """
    (function () {
      if (window.cmuxTheme) return;
      var style = null;
      function ensureStyle() {
        if (style || !document.documentElement) return;
        style = document.createElement('style');
        style.id = 'cmux-theme';
        style.textContent = 'html{background:var(--cmux-surface-background) !important}' +
          'body{background:transparent !important}';
        (document.head || document.documentElement).appendChild(style);
      }
      window.cmuxTheme = {
        current: null,
        apply: function (payload) {
          var root = document.documentElement;
          ensureStyle();
          for (var name in payload.variables) root.style.setProperty(name, payload.variables[name]);
          root.style.colorScheme = payload.colorScheme;
          if (payload.scrollers) root.setAttribute('data-scrollers', payload.scrollers);
          window.cmuxTheme.current = payload;
          window.dispatchEvent(new CustomEvent('cmux-theme', { detail: payload }));
        }
      };
      ensureStyle();
    })();
    """

    /// `#rrggbb`, opaque (the alpha is dropped).
    static func hex(_ color: ThemeRGB) -> String {
        func channel(_ value: Double) -> Int { min(max(Int((value * 255).rounded()), 0), 255) }
        return String(format: "#%02x%02x%02x", channel(color.red), channel(color.green), channel(color.blue))
    }

    /// `rgba(r, g, b, a)` with 0-255 channels.
    public static func css(_ color: ThemeRGB) -> String {
        func channel(_ value: Double) -> Int { Int((value * 255).rounded()) }
        let alpha = (color.alpha * 1000).rounded() / 1000
        return "rgba(\(channel(color.red)), \(channel(color.green)), \(channel(color.blue)), \(alpha))"
    }
}
