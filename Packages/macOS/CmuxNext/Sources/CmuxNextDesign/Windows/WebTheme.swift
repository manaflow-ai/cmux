public import Foundation
public import CmuxNextDesignTokens

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
    /// `static` or `animated` (cx-sya4n): `data-status-indicators` on `<html>`, under which a
    /// page's stylesheets stop their status loops. Static under Reduce Motion or
    /// `appearance.statusIndicator.animation: "static"` (`StatusIndicatorConfig.isStatic`).
    public let statusIndicators: String
    /// `breathe`, `shimmer` or `spinner` (``StatusWorkingLook``): `data-working-look` on `<html>`,
    /// how a page draws agent work.
    public let workingLook: String
    /// `off`, `reduced` or `full` (``motionValue(_:)``): `data-cmux-motion` on `<html>`. Under
    /// `off` the bootstrap stylesheet makes every CSS transition and animation instant
    /// (`ui.animations.web` or the master switch `ui.animations.enabled` off).
    public let motion: String
    /// `lens`, `plain` or `spectrum` (``GlassLensMode/current``, already `plain` under Reduce
    /// Transparency and Low Power Mode): `data-glass` on `<html>`, which `.ui-glass` reads.
    public let glass: String

    /// The terminal colors a page highlights code with: the scope's opaque background and
    /// readable foreground, and its ANSI palette as the theme names it (the page lifts each
    /// slot only as far as it needs to read).
    public nonisolated struct Terminal: Equatable, Sendable {
        public let type: String
        public let background: String
        public let foreground: String
        public let palette: [String: String]
        /// The app's one highlight (`ThemeTokens.textSelection`: the terminal's selection color,
        /// `appearance.highlightColor` over it): code pages (diffs, Markdown code, the editor)
        /// select in it, as text fields and the rest of the page do.
        public let selectionBackground: String
        /// The terminal's font family (`DesignSettings.effectiveTerminalFontFamily`); nil when
        /// neither cmux.json nor the Ghostty config names one.
        public let fontFamily: String?

        init(_ tokens: ThemeTokens, fontFamily: String?) {
            type = tokens.isDark ? "dark" : "light"
            background = WebTheme.hex(tokens.surfaceBackground)
            foreground = WebTheme.hex(tokens.textPrimary)
            palette = Dictionary(uniqueKeysWithValues: tokens.ansi.prefix(16).enumerated().map { (String($0.offset), WebTheme.hex($0.element)) })
            selectionBackground = WebTheme.hex(tokens.textSelection)
            self.fontFamily = fontFamily
        }

        var json: [String: Any] {
            ["type": type, "background": background, "foreground": foreground, "palette": palette,
             "selectionBackground": selectionBackground, "fontFamily": fontFamily.map { $0 as Any } ?? NSNull()]
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
    /// - Parameter glass: The glass mode pages draw; nil reads ``GlassLensMode/current``.
    @MainActor
    public init(_ tokens: ThemeTokens, reduceTransparency: Bool = false, surface surfaceKind: SurfaceKind? = nil,
                backgrounds: SurfaceBackgrounds = ThemeScope.app.surfaceBackgrounds, scrollers: String? = nil,
                app: AppTheme? = nil, glass: GlassLensMode? = nil) {
        let pageOpaque = WindowBackdrop.current(tokens, reduceTransparency: reduceTransparency).panesPaintBackground
        let surface = tokens.surfaceBackground
        let windowTint = WindowBackdrop.currentTint(tokens)
        let page = surfaceKind.flatMap { backgrounds.fill(for: $0, tokens: tokens, windowTint: windowTint) }
            ?? (pageOpaque ? surface.withAlpha(1) : surface.withAlpha(0))
        let cardMaterial = CardMaterial(tokens, lift: ChromeTunables.opaqueOverlayLift.value,
                                        minimumOpacity: ChromeTunables.cardOpacity.value)
        let tooltip = TooltipSurface(tokens, lift: ChromeTunables.opaqueOverlayLift.value)
        variables = [
            "--cmux-surface-background": Self.css(page),
            "--cmux-surface-token": Self.css(surface),
            // The page color made opaque (its own background over the theme's, if it has one),
            // for rings, pills and glyphs on fills that must hide what is under them.
            "--cmux-surface-solid": Self.css(surfaceKind.map {
                backgrounds.opaqueFill(for: $0, tokens: tokens, base: surface.withAlpha(1), windowTint: windowTint)
            } ?? surface.withAlpha(1)),
            "--cmux-elevated-background": Self.css(tokens.elevatedBackground),
            // The solid surface of menus, popovers and tooltips (`--surface-popup`), the same
            // opaque fill as native overlays (`Palette.popupSurface`).
            "--cmux-popup-surface": Self.css(tokens.opaqueOverlayFill(lift: ChromeTunables.opaqueOverlayLift.value)),
            // The tooltip's frosted tint and its ink (`TooltipSurface`, the native tooltip's): the
            // popup surface at the least alpha that keeps the ink 4.5:1 over any backdrop, never
            // solid; the ink is the text unless a low-contrast theme needs it pushed.
            "--cmux-tooltip-tint": Self.css(tooltip.tint),
            "--cmux-tooltip-ink": Self.css(tooltip.ink),
            // Floating cards' material (`CardMaterial`, the native `makeOverlayPanel` cards and the
            // find pill): the popup surface, mostly opaque, at the least alpha that keeps primary
            // and secondary text 4.5:1 over any backdrop, and its rim.
            "--cmux-card-tint": Self.css(cardMaterial.tint),
            "--cmux-card-rim": Borders.drawsLines ? Self.css(cardMaterial.rim) : "transparent",
            "--cmux-text": Self.css(tokens.textPrimary),
            "--cmux-text-secondary": Self.css(tokens.textSecondary),
            "--cmux-text-tertiary": Self.css(tokens.textTertiary),
            "--cmux-separator": Borders.drawsLines ? Self.css(tokens.separator) : "transparent",
            "--cmux-hover": Self.css(tokens.hoverFill),
            "--cmux-selection": Self.css(tokens.selectionFill),
            // Selected text and the caret in the Ghostty config's colors (`selection-background`,
            // with `appearance.highlightColor` over it, and `cursor-color`). Without a readable
            // selection color, the same derived one as native text fields and the omnibar
            // (`Palette.textSelection`): one highlight app-wide (user 2026-10-28).
            "--cmux-text-selection": Self.css(tokens.textSelection),
            "--cmux-caret": Self.css(tokens.caret),
            // The accent and the glyphs on it (`ThemeTokens.accent`: the text color, or the
            // theme's own hue with appearance.accent).
            "--cmux-accent": Self.css(tokens.accent),
            "--cmux-on-accent": Self.css(tokens.onAccent),
            // A lit (pressed, on) control's glyph: the accent, never fainter than at rest (`ThemeTokens.litGlyph`).
            "--cmux-lit-glyph": Self.css(tokens.litGlyph),
            // The modal scrim (`Scrim`), the same as native dialogs'.
            "--cmux-scrim": Self.css(tokens.scrim),
        ].merging((app ?? ThemeScope.app.store.appTheme ?? tokens.app).cssVariables) { own, _ in own }
        colorScheme = tokens.isDark ? "dark" : "light"
        let colors = ColorTransition.current
        transition = ["duration": colors.cssDuration, "easing": colors.cssEasing, "space": colors.space.rawValue]
        self.scrollers = scrollers ?? SystemScrollers.pageValue
        terminal = Terminal(tokens, fontFamily: DesignSettings.shared.effectiveTerminalFontFamily)
        statusIndicators = !Motion.indicators.animatesLoops || DesignSettings.shared.statusIndicator.animation == .static ? "static" : "animated"
        workingLook = StatusWorkingLook.tunable.value.rawValue
        motion = Self.motionValue(Motion.web.policy)
        self.glass = (glass ?? .current).rawValue
    }

    /// `data-cmux-motion` for `policy`: `off` when the web category, the master switch or speed
    /// is off (the bootstrap stylesheet then ends every transition and animation at once),
    /// `reduced` under Reduce Motion, else `full`.
    public static func motionValue(_ policy: MotionPolicy) -> String {
        guard policy.categoryAnimates else { return "off" }
        return policy.reduceMotion ? "reduced" : "full"
    }

    /// The payload `window.cmuxTheme.apply` takes: `{variables, colorScheme, scrollers, terminal, statusIndicators, workingLook, motion, glass}`
    /// (`terminal.fontFamily` is null when the terminal has no named face).
    /// How the page's color variables move to new values (`appearance.colorTransition`, the same
    /// duration, curve and blend space as native): `{duration, easing, space}`.
    public let transition: [String: String]

    public var payloadJSON: String {
        let object: [String: Any] = ["variables": variables, "colorScheme": colorScheme, "scrollers": scrollers,
                                     "terminal": terminal.json, "transition": transition, "statusIndicators": statusIndicators,
                                     "workingLook": workingLook, "motion": motion, "glass": glass]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }

    /// Applies this theme to a page that ran ``bootstrapScript``.
    public var applyScript: String { "window.cmuxTheme && window.cmuxTheme.apply(\(payloadJSON));" }

    /// Defines `window.cmuxTheme` (`apply(payload)` and `backdrop(partial)`, which merges into
    /// `window.cmuxBackdropState` and dispatches `cmux-backdrop`) and the page background rule.
    /// Install it at document start in every cmux-owned web view.
    public static let bootstrapScript = """
    (function () {
      if (window.cmuxTheme) return;
      var style = null;
      function ensureStyle() {
        if (style || !document.documentElement) return;
        style = document.createElement('style');
        style.id = 'cmux-theme';
        // ui.animations.web off (or the master switch off): every CSS transition and animation of
        // the page ends at once, so a page needs no code of its own to work with no motion.
        var still = 'html[data-cmux-motion="off"]';
        style.textContent = 'html{background:var(--cmux-surface-background) !important}' +
          'body{background:transparent !important}' +
          still + ' *,' + still + ' *::before,' + still + ' *::after,' + still +
          '{transition-duration:0s !important;transition-delay:0s !important;animation-duration:0s !important;' +
          'animation-delay:0s !important;animation-iteration-count:1 !important;scroll-behavior:auto !important}';
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
      // A theme applied before <html> exists (Chromium new-document scripts), and the watch that
      // applies it, with the page background rule, once the parser inserts the root.
      var pendingPayload = null;
      var rootWatch = null;
      function awaitRoot() {
        if (rootWatch || !window.MutationObserver) return;
        rootWatch = new MutationObserver(function () {
          if (!document.documentElement) return;
          rootWatch.disconnect();
          rootWatch = null;
          ensureStyle();
          var payload = pendingPayload;
          pendingPayload = null;
          if (payload) window.cmuxTheme.apply(payload);
        });
        rootWatch.observe(document, { childList: true });
      }
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
          // Chromium runs new-document scripts before the parser makes <html>, so its document-start
          // apply finds no root. It waits for one (awaitRoot): registering every color first and then
          // throwing in setTransition left each one at its initial transparent, text and background.
          if (!root) {
            pendingPayload = payload;
            awaitRoot();
            return;
          }
          pendingPayload = null; // a theme applied since wins over one still waiting for the root
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
          if (payload.statusIndicators) root.setAttribute('data-status-indicators', payload.statusIndicators);
          if (payload.workingLook) root.setAttribute('data-working-look', payload.workingLook);
          if (payload.motion) root.setAttribute('data-cmux-motion', payload.motion);
          if (payload.glass) root.setAttribute('data-glass', payload.glass);
          window.cmuxTheme.current = payload;
          window.dispatchEvent(new CustomEvent('cmux-theme', { detail: payload }));
          if (!first) settled(payload);
        },
        // The wallpaper still the page's glass lenses (GlassBackdropFeed): each push carries only
        // what changed, merged over the last state, then `cmux-backdrop` tells the page.
        backdrop: function (partial) {
          var next = Object.assign({}, window.cmuxBackdropState || {});
          for (var field in partial) if (Object.prototype.hasOwnProperty.call(partial, field)) next[field] = partial[field];
          window.cmuxBackdropState = next;
          window.dispatchEvent(new Event('cmux-backdrop'));
        }
      };
      if (document.documentElement) ensureStyle(); else awaitRoot();
      // ui.animations.web off: script animations (Element.animate) and smooth scrolls end at once
      // too, which the stylesheet above cannot reach. One wrapper per prototype, read on each call,
      // so turning the switch back on restores them with no reload.
      function still() { return document.documentElement && document.documentElement.getAttribute('data-cmux-motion') === 'off'; }
      if (window.Element && Element.prototype.animate && !Element.prototype.animate.cmuxMotion) {
        var animate = Element.prototype.animate;
        var gated = function (keyframes, options) {
          if (!still()) return animate.call(this, keyframes, options);
          var timing = typeof options === 'number' || options == null ? {} : Object.assign({}, options);
          timing.duration = 0;
          timing.delay = 0;
          timing.endDelay = 0;
          timing.iterations = 1;
          return animate.call(this, keyframes, timing);
        };
        gated.cmuxMotion = true;
        Element.prototype.animate = gated;
      }
      function instant(original) {
        var gatedScroll = function (a, b) {
          if (still() && a && typeof a === 'object' && a.behavior) a = Object.assign({}, a, { behavior: 'instant' });
          return arguments.length > 1 ? original.call(this, a, b) : original.call(this, a);
        };
        gatedScroll.cmuxMotion = true;
        return gatedScroll;
      }
      ['scrollTo', 'scrollBy', 'scrollIntoView'].forEach(function (name) {
        if (window.Element && Element.prototype[name] && !Element.prototype[name].cmuxMotion) Element.prototype[name] = instant(Element.prototype[name]);
      });
      ['scrollTo', 'scrollBy'].forEach(function (name) {
        if (window[name] && !window[name].cmuxMotion) window[name] = instant(window[name]);
      });
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

    /// `color` as pages read it from `css`: each channel rounded to 8 bits, the alpha to 3 decimals.
    public static func cssRounded(_ color: ThemeRGB) -> ThemeRGB {
        func channel(_ value: Double) -> Double { (value * 255).rounded() / 255 }
        return ThemeRGB(red: channel(color.red), green: channel(color.green), blue: channel(color.blue),
                        alpha: (color.alpha * 1000).rounded() / 1000)
    }
}
