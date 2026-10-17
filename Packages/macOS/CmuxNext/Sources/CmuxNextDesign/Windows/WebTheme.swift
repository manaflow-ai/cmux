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
    /// color code from its ANSI palette (syntax-theme.ts), as the agent chat and Ghostty do. Its
    /// `fontFamily` is the terminal's face, which pages that show code draw it in (appearance.ts).
    public let terminal: Terminal

    /// The terminal colors a page highlights code with: the scope's opaque background and
    /// readable foreground, and its ANSI palette as the theme names it (the page lifts each
    /// slot only as far as it needs to read).
    public nonisolated struct Terminal: Equatable, Sendable {
        public let type: String
        public let background: String
        public let foreground: String
        public let palette: [String: String]
        /// The terminal's font family (`DesignSettings.effectiveTerminalFontFamily`); nil when
        /// neither cmux.json nor the Ghostty config names one.
        public let fontFamily: String?

        init(_ tokens: ThemeTokens, fontFamily: String?) {
            type = tokens.isDark ? "dark" : "light"
            background = WebTheme.hex(tokens.surfaceBackground)
            foreground = WebTheme.hex(tokens.textPrimary)
            palette = Dictionary(uniqueKeysWithValues: tokens.ansi.prefix(16).enumerated().map { (String($0.offset), WebTheme.hex($0.element)) })
            self.fontFamily = fontFamily
        }

        var json: [String: Any] {
            ["type": type, "background": background, "foreground": foreground, "palette": palette,
             "fontFamily": fontFamily.map { $0 as Any } ?? NSNull()]
        }
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
            // The tooltip's frosted tint (`TooltipSurface`, the native tooltip's): the popup
            // surface at the least alpha that keeps the text 4.5:1 over any backdrop.
            "--cmux-tooltip-tint": Self.css(TooltipSurface(tokens, lift: ChromeTunables.opaqueOverlayLift.value).tint),
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
        let colors = ColorTransition.current
        transition = ["duration": colors.cssDuration, "easing": colors.cssEasing, "space": colors.space.rawValue]
        self.scrollers = scrollers ?? SystemScrollers.pageValue
        terminal = Terminal(tokens, fontFamily: DesignSettings.shared.effectiveTerminalFontFamily)
    }

    /// The payload `window.cmuxTheme.apply` takes: `{variables, colorScheme, scrollers, terminal}`
    /// (`terminal.fontFamily` is null when the terminal has no named face).
    /// How the page's color variables move to new values (`appearance.colorTransition`, the same
    /// duration, curve and blend space as native): `{duration, easing, space}`.
    public let transition: [String: String]

    public var payloadJSON: String {
        let object: [String: Any] = ["variables": variables, "colorScheme": colorScheme, "scrollers": scrollers,
                                     "terminal": terminal.json, "transition": transition]
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
      // appearance.colorTransition: every color variable is a registered <color>, so a theme or
      // workspace change transitions it (and everything that reads it) from the value on screen;
      // a quick second change retargets from the blend in flight. OKLab blends need non-legacy
      // color syntax (CSS Color 4 mixes two rgb() or hex values in sRGB). Code that reads computed
      // colors gets a second `cmux-theme` event once the blend ends.
      var registered = {};
      var applied = {};
      var transitionStyle = null;
      // rgb()/rgba() parsed without a regular expression: the literal stays free of backslashes
      // (Swift escapes), so the gallery runs the same script (webviews/dev-server/galleryHost.ts).
      function rgba(value) {
        var open = value.indexOf('('), close = value.lastIndexOf(')');
        if (value.slice(0, 3) !== 'rgb' || open < 3 || close !== value.length - 1) return null;
        var parts = value.slice(open + 1, close).split(',').map(function (p) { return Number(p.trim()); });
        if (parts.length < 3 || parts.length > 4 || parts.some(function (n) { return !isFinite(n); })) return null;
        return parts;
      }
      var hex = /^#([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})?$/i;
      function colorValue(value, space) {
        if (space !== 'oklab') return value;
        var c = rgba(value);
        if (c) return 'color(srgb ' + (c[0] / 255) + ' ' + (c[1] / 255) + ' ' + (c[2] / 255) + ' / ' + (c[3] === undefined ? 1 : c[3]) + ')';
        var m = hex.exec(value);
        if (m) return 'color(srgb ' + (parseInt(m[1], 16) / 255) + ' ' + (parseInt(m[2], 16) / 255) + ' ' + (parseInt(m[3], 16) / 255) +
          ' / ' + (m[4] === undefined ? 1 : parseInt(m[4], 16) / 255) + ')';
        return value;
      }
      function register(name, value) {
        if (registered[name] !== undefined) return registered[name];
        var ok = !!(window.CSS && CSS.registerProperty && CSS.supports && value.indexOf('var(') < 0 && CSS.supports('color', value));
        if (ok) {
          try { CSS.registerProperty({ name: name, syntax: '<color>', inherits: true, initialValue: 'transparent' }); } catch (e) { ok = false; }
        }
        registered[name] = ok;
        return ok;
      }
      function setTransition(transition, names) {
        if (!transitionStyle) {
          transitionStyle = document.createElement('style');
          transitionStyle.id = 'cmux-theme-transition';
          (document.head || document.documentElement).appendChild(transitionStyle);
        }
        var duration = (transition && transition.duration) || '0ms';
        var text = names.length && duration !== '0ms'
          ? 'html{transition-property:' + names.join(',') + ';transition-duration:' + duration +
            ';transition-timing-function:' + ((transition && transition.easing) || 'ease-out') + '}'
          : '';
        // A rewrite restyles the whole document: only when the rule changed.
        if (transitionStyle.textContent !== text) transitionStyle.textContent = text;
      }
      function settled(payload) {
        var root = document.documentElement;
        var running = root.getAnimations ? root.getAnimations().filter(function (a) { return a.transitionProperty; }) : [];
        if (!running.length) return;
        Promise.allSettled(running.map(function (a) { return a.finished; })).then(function () {
          if (window.cmuxTheme.current === payload) window.dispatchEvent(new CustomEvent('cmux-theme', { detail: payload }));
        });
      }
      window.cmuxTheme = {
        current: null,
        apply: function (payload) {
          var root = document.documentElement;
          ensureStyle();
          var first = window.cmuxTheme.current === null;
          var space = payload.transition && payload.transition.space;
          var names = [];
          for (var key in payload.variables) if (register(key, payload.variables[key])) names.push(key);
          // The first theme of a page shows at once (no fade in from transparent): the values
          // land with no transition, a style read commits them, then the transition turns on.
          if (first) setTransition(null, names);
          for (var name in payload.variables) {
            var value = registered[name] ? colorValue(payload.variables[name], space) : payload.variables[name];
            // Only the variables that changed: an unchanged one restyles nothing.
            if (applied[name] === value) continue;
            applied[name] = value;
            root.style.setProperty(name, value);
          }
          if (first && names.length) getComputedStyle(root).getPropertyValue(names[0]);
          setTransition(payload.transition, names);
          root.style.colorScheme = payload.colorScheme;
          if (payload.scrollers) root.setAttribute('data-scrollers', payload.scrollers);
          window.cmuxTheme.current = payload;
          window.dispatchEvent(new CustomEvent('cmux-theme', { detail: payload }));
          if (!first) settled(payload);
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
