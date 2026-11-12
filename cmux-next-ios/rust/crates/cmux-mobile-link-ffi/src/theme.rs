//! The Mac's theme derivation for the phone (PROTOCOL.md "Appearance"):
//! `cmux-theme-tokens::ThemeTokens::derive`, the code the Mac's chrome is
//! drawn with, behind uniffi, so the phone derives every color of a Mac's
//! `get-appearance` snapshot (or of its own Personalization choice) exactly
//! as the Mac does. Colors cross as 0...1 components; inputs cross as the
//! snapshot's `#RRGGBB` strings and are parsed with the Mac's own parser.

use cmux_theme_tokens::{Rgb, ThemeAccent, ThemeInput, ThemeTokens, parse_color, readable};

/// One sRGB color, components 0...1.
#[derive(Debug, Clone, Copy, PartialEq, uniffi::Record)]
pub struct ThemeColor {
    pub r: f64,
    pub g: f64,
    pub b: f64,
    pub a: f64,
}

impl From<Rgb> for ThemeColor {
    fn from(c: Rgb) -> Self {
        Self { r: c.r, g: c.g, b: c.b, a: c.a }
    }
}

impl From<ThemeColor> for Rgb {
    fn from(c: ThemeColor) -> Self {
        Rgb::new(c.r, c.g, c.b, c.a)
    }
}

/// `cmux-theme-tokens::ThemeInput` as the snapshot's JSON carries it
/// (`THEME_INPUT`): colors are `#RRGGBB` (or anything Ghostty's parser
/// takes), optional ones nil when unset; `accent` is `appearance.accent`.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ThemeInputWire {
    pub background: String,
    pub foreground: String,
    /// ANSI 0...15; missing or unreadable entries keep Ghostty's default.
    pub palette: Vec<String>,
    pub selection_background: Option<String>,
    pub selection_foreground: Option<String>,
    pub cursor: Option<String>,
    pub background_opacity: f64,
    pub background_blur: i32,
    /// `neutral`, `theme`, `red`, ... (unknown: neutral).
    pub accent: String,
    pub accent_color: Option<String>,
}

/// Every chrome color `ThemeTokens::derive` gives, plus the popup surface
/// (`opaque_overlay_fill(0.06)`), field for field.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct DerivedThemeTokens {
    pub is_dark: bool,
    pub window_background: ThemeColor,
    pub sidebar_background: ThemeColor,
    pub content_background: ThemeColor,
    pub chrome_background: ThemeColor,
    pub elevated_background: ThemeColor,
    pub strip_background: ThemeColor,
    pub sidebar_step: ThemeColor,
    pub strip_step: ThemeColor,
    pub text_primary: ThemeColor,
    pub text_secondary: ThemeColor,
    pub text_tertiary: ThemeColor,
    pub hover_fill: ThemeColor,
    pub selection_fill: ThemeColor,
    pub secondary_selection_fill: ThemeColor,
    pub pressed_fill: ThemeColor,
    pub badge_fill: ThemeColor,
    pub separator: ThemeColor,
    pub pane_border: ThemeColor,
    pub focus_ring: ThemeColor,
    pub glass_tint: ThemeColor,
    pub shadow: ThemeColor,
    pub text_selection: ThemeColor,
    pub attention: ThemeColor,
    pub danger: ThemeColor,
    pub success: ThemeColor,
    pub highlight: ThemeColor,
    pub highlight_text: ThemeColor,
    pub accent: ThemeColor,
    pub on_accent: ThemeColor,
    pub ansi: Vec<ThemeColor>,
    pub background_opacity: f64,
    pub background_blur: i32,
    pub caret: ThemeColor,
    /// The opaque popup and card surface (`opaque_overlay_fill(0.06)`).
    pub overlay_fill: ThemeColor,
    /// The theme's terminal colors as parsed (what the terminal draws).
    pub terminal_background: ThemeColor,
    pub terminal_foreground: ThemeColor,
    pub selection_background: Option<ThemeColor>,
    pub selection_foreground: Option<ThemeColor>,
    pub cursor: Option<ThemeColor>,
}

fn color(value: &str) -> Option<Rgb> {
    parse_color(value)
}

/// The `ThemeInput` of a wire input; unreadable colors keep Ghostty's
/// default theme's.
pub fn theme_input(wire: &ThemeInputWire) -> ThemeInput {
    let base = ThemeInput::GHOSTTY_DEFAULT;
    let mut palette = base.palette;
    for (slot, value) in palette.iter_mut().zip(&wire.palette) {
        if let Some(c) = color(value) {
            *slot = c;
        }
    }
    let opacity =
        if wire.background_opacity.is_finite() { wire.background_opacity.clamp(0.0, 1.0) } else { 1.0 };
    ThemeInput {
        background: color(&wire.background).unwrap_or(base.background),
        foreground: color(&wire.foreground).unwrap_or(base.foreground),
        palette,
        selection_background: wire.selection_background.as_deref().and_then(color),
        selection_foreground: wire.selection_foreground.as_deref().and_then(color),
        background_opacity: opacity,
        background_blur: wire.background_blur,
        cursor: wire.cursor.as_deref().and_then(color),
        accent: ThemeAccent::parse(wire.accent.trim()).unwrap_or_default(),
        accent_color: wire.accent_color.as_deref().and_then(color),
    }
}

/// Every chrome color of `input`, derived by the Mac's own code.
#[uniffi::export]
pub fn derive_theme_tokens(input: ThemeInputWire) -> DerivedThemeTokens {
    let parsed = theme_input(&input);
    let t = ThemeTokens::derive(&parsed);
    let c = ThemeColor::from;
    DerivedThemeTokens {
        is_dark: t.is_dark,
        window_background: c(t.window_background),
        sidebar_background: c(t.sidebar_background),
        content_background: c(t.content_background),
        chrome_background: c(t.chrome_background),
        elevated_background: c(t.elevated_background),
        strip_background: c(t.strip_background),
        sidebar_step: c(t.sidebar_step),
        strip_step: c(t.strip_step),
        text_primary: c(t.text_primary),
        text_secondary: c(t.text_secondary),
        text_tertiary: c(t.text_tertiary),
        hover_fill: c(t.hover_fill),
        selection_fill: c(t.selection_fill),
        secondary_selection_fill: c(t.secondary_selection_fill),
        pressed_fill: c(t.pressed_fill),
        badge_fill: c(t.badge_fill),
        separator: c(t.separator),
        pane_border: c(t.pane_border),
        focus_ring: c(t.focus_ring),
        glass_tint: c(t.glass_tint),
        shadow: c(t.shadow),
        text_selection: c(t.text_selection),
        attention: c(t.attention),
        danger: c(t.danger),
        success: c(t.success),
        highlight: c(t.highlight),
        highlight_text: c(t.highlight_text),
        accent: c(t.accent),
        on_accent: c(t.on_accent),
        ansi: t.ansi.iter().copied().map(c).collect(),
        background_opacity: t.background_opacity,
        background_blur: t.background_blur,
        caret: c(t.caret),
        overlay_fill: c(t.opaque_overlay_fill(0.06)),
        terminal_background: c(parsed.background),
        terminal_foreground: c(parsed.foreground),
        selection_background: parsed.selection_background.map(c),
        selection_foreground: parsed.selection_foreground.map(c),
        cursor: parsed.cursor.map(c),
    }
}

/// `color` pushed away from `surface` until it has `minimum` contrast
/// (`cmux-theme-tokens::readable`, the Mac's status-color rule).
#[uniffi::export]
pub fn theme_readable(color: ThemeColor, surface: ThemeColor, minimum: f64) -> ThemeColor {
    readable(color.into(), surface.into(), minimum).into()
}

/// WCAG 2 contrast between two opaque colors (1...21).
#[uniffi::export]
pub fn theme_contrast(a: ThemeColor, b: ThemeColor) -> f64 {
    Rgb::from(a).contrast(b.into())
}

#[cfg(test)]
mod tests {
    use super::*;

    const NORD: [&str; 16] = [
        "#3B4252", "#BF616A", "#A3BE8C", "#EBCB8B", "#81A1C1", "#B48EAD", "#88C0D0", "#E5E9F0", "#4C566A",
        "#BF616A", "#A3BE8C", "#EBCB8B", "#81A1C1", "#B48EAD", "#8FBCBB", "#ECEFF4",
    ];

    fn nord(accent: &str) -> ThemeInputWire {
        ThemeInputWire {
            background: "#2E3440".into(),
            foreground: "#D8DEE9".into(),
            palette: NORD.iter().map(|s| (*s).to_string()).collect(),
            selection_background: None,
            selection_foreground: None,
            cursor: Some("#ECEFF4".into()),
            background_opacity: 1.0,
            background_blur: 0,
            accent: accent.into(),
            accent_color: None,
        }
    }

    #[test]
    fn derives_what_the_mac_derives() {
        let wire = nord("neutral");
        let ours = derive_theme_tokens(wire.clone());
        let mac = ThemeTokens::derive(&theme_input(&wire));
        assert!(ours.is_dark);
        assert_eq!(ours.window_background, ThemeColor::from(mac.window_background));
        assert_eq!(ours.text_primary, ThemeColor::from(mac.text_primary));
        assert_eq!(ours.selection_fill, ThemeColor::from(mac.selection_fill));
        assert_eq!(ours.ansi.len(), 16);
        assert_eq!(ours.ansi[4], ThemeColor::from(Rgb::hex(0x81A1C1)));
        assert_eq!(ours.terminal_background, ThemeColor::from(Rgb::hex(0x2E3440)));
        assert!(theme_contrast(ours.text_primary, ours.window_background) >= 4.5);
    }

    #[test]
    fn a_named_accent_takes_the_theme_hue() {
        let neutral = derive_theme_tokens(nord("neutral"));
        let blue = derive_theme_tokens(nord("blue"));
        assert_ne!(neutral.accent, blue.accent);
        assert_eq!(neutral.accent, neutral.text_primary);
        assert!(theme_contrast(blue.on_accent, blue.accent) >= 4.5);
    }

    #[test]
    fn unreadable_input_keeps_ghostty_defaults() {
        let mut wire = nord("bogus");
        wire.background = "not a color".into();
        wire.palette.truncate(3);
        let input = theme_input(&wire);
        assert_eq!(input.background, ThemeInput::GHOSTTY_DEFAULT.background);
        assert_eq!(input.palette[5], ThemeInput::GHOSTTY_DEFAULT.palette[5]);
        assert_eq!(input.accent, ThemeAccent::Neutral);
    }

    #[test]
    fn readable_reaches_the_minimum() {
        let dim = ThemeColor { r: 0.2, g: 0.2, b: 0.25, a: 1.0 };
        let bg = ThemeColor::from(Rgb::hex(0x2E3440));
        assert!(theme_contrast(theme_readable(dim, bg, 3.0), bg) >= 3.0);
    }
}
