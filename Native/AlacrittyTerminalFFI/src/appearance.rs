use alacritty_terminal::vte::ansi::NamedColor;
use serde::Deserialize;

use crate::display::color::Rgb;

#[derive(Clone, Debug, PartialEq)]
pub struct TerminalAppearance {
    font_family: String,
    font_size_points: f32,
    background: Rgb,
    foreground: Rgb,
    bold_color: Option<BoldColor>,
    cursor: Rgb,
    cursor_color_semantic: Option<CellRelativeColor>,
    cursor_text: Option<Rgb>,
    cursor_text_semantic: Option<CellRelativeColor>,
    selection_background: Rgb,
    selection_background_semantic: Option<CellRelativeColor>,
    selection_foreground: Rgb,
    selection_foreground_semantic: Option<CellRelativeColor>,
    palette: Vec<Rgb>,
}

impl TerminalAppearance {
    pub fn from_json(json: &str) -> Result<Self, String> {
        let wire: AppearanceWire =
            serde_json::from_str(json).map_err(|error| format!("decode appearance: {error}"))?;
        let font_family = wire.font_family.trim();
        let font_family = if font_family.is_empty() {
            String::from("Menlo")
        } else {
            String::from(font_family)
        };
        let font_size_points = if wire.font_size_points.is_finite() {
            wire.font_size_points.max(6.0)
        } else {
            12.0
        };
        let palette_count = wire.theme.palette.len();
        if palette_count != 16 && palette_count != 256 {
            return Err(format!(
                "appearance palette must contain 16 or 256 colors, got {palette_count}"
            ));
        }
        let palette = wire
            .theme
            .palette
            .iter()
            .enumerate()
            .map(|(index, color)| {
                parse_rgb(color).map_err(|error| format!("palette[{index}]: {error}"))
            })
            .collect::<Result<Vec<_>, _>>()?;
        let bold_color = wire
            .theme
            .bold_color
            .as_deref()
            .map(BoldColor::parse)
            .transpose()?;

        Ok(Self {
            font_family,
            font_size_points,
            background: parse_rgb(&wire.theme.background)?,
            foreground: parse_rgb(&wire.theme.foreground)?,
            bold_color,
            cursor: parse_rgb(&wire.theme.cursor)?,
            cursor_color_semantic: wire
                .theme
                .cursor_color_semantic
                .as_deref()
                .map(CellRelativeColor::parse)
                .transpose()?,
            cursor_text: wire
                .theme
                .cursor_text
                .as_deref()
                .map(parse_rgb)
                .transpose()?,
            cursor_text_semantic: wire
                .theme
                .cursor_text_semantic
                .as_deref()
                .map(CellRelativeColor::parse)
                .transpose()?,
            selection_background: parse_rgb(&wire.theme.selection_background)?,
            selection_background_semantic: wire
                .theme
                .selection_background_semantic
                .as_deref()
                .map(CellRelativeColor::parse)
                .transpose()?,
            selection_foreground: parse_rgb(&wire.theme.selection_foreground)?,
            selection_foreground_semantic: wire
                .theme
                .selection_foreground_semantic
                .as_deref()
                .map(CellRelativeColor::parse)
                .transpose()?,
            palette,
        })
    }

    pub fn font_family(&self) -> &str {
        &self.font_family
    }

    pub fn font_size_points(&self) -> f32 {
        self.font_size_points
    }

    pub fn background(&self) -> Rgb {
        self.background
    }

    pub fn color(&self, index: usize) -> Rgb {
        if let Some(color) = self.palette.get(index) {
            return *color;
        }

        match index {
            16..=231 => {
                let value = index - 16;
                let component = |component: usize| {
                    if component == 0 {
                        0
                    } else {
                        (component * 40 + 55) as u8
                    }
                };
                Rgb::new(
                    component(value / 36),
                    component((value / 6) % 6),
                    component(value % 6),
                )
            }
            232..=255 => {
                let value = ((index - 232) * 10 + 8) as u8;
                Rgb::new(value, value, value)
            }
            value if value == NamedColor::Background as usize => self.background,
            value if value == NamedColor::Foreground as usize => self.foreground,
            value if value == NamedColor::Cursor as usize => self.cursor,
            value if value == NamedColor::BrightForeground as usize => match self.bold_color {
                Some(BoldColor::Color(color)) => color,
                Some(BoldColor::Bright) | None => self.foreground,
            },
            value if value == NamedColor::DimForeground as usize => dimmed(self.foreground),
            259..=266 => self
                .palette
                .get(index - 259)
                .copied()
                .map(dimmed)
                .unwrap_or(self.foreground),
            _ => self.foreground,
        }
    }

    pub fn cursor_colors(&self, cell_foreground: Rgb, cell_background: Rgb) -> (Rgb, Rgb) {
        let cursor_background = self
            .cursor_color_semantic
            .map(|semantic| semantic.resolve(cell_foreground, cell_background))
            .unwrap_or(self.cursor);
        let cursor_foreground = self
            .cursor_text_semantic
            .map(|semantic| semantic.resolve(cell_foreground, cell_background))
            .or(self.cursor_text)
            .unwrap_or(cell_background);
        (cursor_foreground, cursor_background)
    }

    pub fn has_bold_color(&self) -> bool {
        self.bold_color.is_some()
    }

    pub fn bold_named_color(&self, color: NamedColor) -> NamedColor {
        match self.bold_color {
            Some(BoldColor::Color(_)) => color.to_bright(),
            Some(BoldColor::Bright) if color != NamedColor::Foreground => color.to_bright(),
            Some(BoldColor::Bright) | None => color,
        }
    }

    pub fn bold_default_foreground(&self, foreground: Rgb, default_foreground: Rgb) -> Rgb {
        match self.bold_color {
            Some(BoldColor::Color(color)) if foreground == default_foreground => color,
            _ => foreground,
        }
    }

    pub fn selection_colors(&self, cell_foreground: Rgb, cell_background: Rgb) -> (Rgb, Rgb) {
        let selection_background = self
            .selection_background_semantic
            .map(|semantic| semantic.resolve(cell_foreground, cell_background))
            .unwrap_or(self.selection_background);
        let selection_foreground = self
            .selection_foreground_semantic
            .map(|semantic| semantic.resolve(cell_foreground, cell_background))
            .unwrap_or(self.selection_foreground);
        (selection_foreground, selection_background)
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
enum BoldColor {
    Bright,
    Color(Rgb),
}

impl BoldColor {
    fn parse(value: &str) -> Result<Self, String> {
        if value.eq_ignore_ascii_case("bright") {
            Ok(Self::Bright)
        } else {
            parse_rgb(value).map(Self::Color)
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
enum CellRelativeColor {
    Foreground,
    Background,
}

impl CellRelativeColor {
    fn parse(value: &str) -> Result<Self, String> {
        match value {
            "cell-foreground" => Ok(Self::Foreground),
            "cell-background" => Ok(Self::Background),
            _ => Err(format!("invalid cell-relative color '{value}'")),
        }
    }

    fn resolve(self, cell_foreground: Rgb, cell_background: Rgb) -> Rgb {
        match self {
            Self::Foreground => cell_foreground,
            Self::Background => cell_background,
        }
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct AppearanceWire {
    font_family: String,
    font_size_points: f32,
    theme: ThemeWire,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ThemeWire {
    background: String,
    foreground: String,
    bold_color: Option<String>,
    cursor: String,
    cursor_color_semantic: Option<String>,
    cursor_text: Option<String>,
    cursor_text_semantic: Option<String>,
    selection_background: String,
    selection_background_semantic: Option<String>,
    selection_foreground: String,
    selection_foreground_semantic: Option<String>,
    palette: Vec<String>,
}

fn parse_rgb(value: &str) -> Result<Rgb, String> {
    let value = value.strip_prefix('#').unwrap_or(value);
    if value.len() != 6 {
        return Err(format!("invalid RGB color '#{value}'"));
    }
    let raw =
        u32::from_str_radix(value, 16).map_err(|_| format!("invalid RGB color '#{value}'"))?;
    Ok(Rgb::new(
        ((raw >> 16) & 0xff) as u8,
        ((raw >> 8) & 0xff) as u8,
        (raw & 0xff) as u8,
    ))
}

fn dimmed(color: Rgb) -> Rgb {
    Rgb::new(
        (f32::from(color.r) * 0.66) as u8,
        (f32::from(color.g) * 0.66) as u8,
        (f32::from(color.b) * 0.66) as u8,
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    const APPEARANCE_JSON: &str = r##"{
        "fontFamily": "Berkeley Mono",
        "fontSizePoints": 14,
        "theme": {
            "background": "#102030",
            "foreground": "#f0e0d0",
            "boldColor": "#abcdef",
            "cursor": "#345678",
            "cursorColorSemantic": "cell-foreground",
            "cursorText": "#fedcba",
            "cursorTextSemantic": "cell-background",
            "selectionBackground": "#112233",
            "selectionBackgroundSemantic": "cell-foreground",
            "selectionForeground": "#ddeeff",
            "selectionForegroundSemantic": "cell-background",
            "palette": [
                "#000102", "#010203", "#020304", "#030405",
                "#040506", "#050607", "#060708", "#070809",
                "#08090a", "#090a0b", "#0a0b0c", "#0b0c0d",
                "#0c0d0e", "#0d0e0f", "#0e0f10", "#0f1011"
            ]
        }
    }"##;

    #[test]
    fn parses_swift_runtime_appearance_wire_shape() {
        let appearance = TerminalAppearance::from_json(APPEARANCE_JSON).unwrap();

        assert_eq!(appearance.font_family(), "Berkeley Mono");
        assert_eq!(appearance.font_size_points(), 14.0);
        assert_eq!(appearance.background(), Rgb::new(16, 32, 48));
        assert_eq!(appearance.color(0), Rgb::new(0, 1, 2));
        assert_eq!(
            appearance.color(NamedColor::Foreground as usize),
            Rgb::new(240, 224, 208)
        );
        assert_eq!(
            appearance.color(NamedColor::BrightForeground as usize),
            Rgb::new(171, 205, 239)
        );
    }

    #[test]
    fn resolves_cell_relative_cursor_colors_after_theme_mapping() {
        let appearance = TerminalAppearance::from_json(APPEARANCE_JSON).unwrap();

        let colors = appearance.cursor_colors(Rgb::new(1, 2, 3), Rgb::new(4, 5, 6));

        assert_eq!(colors, (Rgb::new(4, 5, 6), Rgb::new(1, 2, 3)));
    }

    #[test]
    fn resolves_cell_relative_selection_colors_after_theme_mapping() {
        let appearance = TerminalAppearance::from_json(APPEARANCE_JSON).unwrap();

        let colors = appearance.selection_colors(Rgb::new(1, 2, 3), Rgb::new(4, 5, 6));

        assert_eq!(colors, (Rgb::new(4, 5, 6), Rgb::new(1, 2, 3)));
    }

    #[test]
    fn applies_ghostty_bold_color_only_to_default_foreground() {
        let appearance = TerminalAppearance::from_json(APPEARANCE_JSON).unwrap();

        assert!(appearance.has_bold_color());
        assert_eq!(
            appearance.bold_default_foreground(Rgb::new(240, 224, 208), Rgb::new(240, 224, 208)),
            Rgb::new(171, 205, 239)
        );
        assert_eq!(
            appearance.bold_default_foreground(Rgb::new(1, 2, 3), Rgb::new(240, 224, 208)),
            Rgb::new(1, 2, 3)
        );
    }

    #[test]
    fn maps_ghostty_bright_mode_without_replacing_default_foreground() {
        let json =
            APPEARANCE_JSON.replace(r##""boldColor": "#abcdef""##, r##""boldColor": "bright""##);
        let appearance = TerminalAppearance::from_json(&json).unwrap();

        assert_eq!(
            appearance.bold_named_color(NamedColor::Foreground),
            NamedColor::Foreground
        );
        assert_eq!(
            appearance.bold_named_color(NamedColor::Red),
            NamedColor::BrightRed
        );
    }

    #[test]
    fn rejects_incomplete_palettes() {
        let json = APPEARANCE_JSON.replace(r##""#0e0f10", "#0f1011""##, r##""#0e0f10""##);

        let error = TerminalAppearance::from_json(&json).unwrap_err();

        assert!(error.contains("must contain 16 or 256 colors"));
    }
}
