pub mod debug {
    #[derive(Copy, Clone, Debug, PartialEq, Eq, PartialOrd, Ord)]
    pub enum RendererPreference {
        Glsl3,
        Gles2,
        Gles2Pure,
    }
}

pub mod ui_config {
    #[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
    pub struct Delta<T: Default> {
        pub x: T,
        pub y: T,
    }
}

pub mod font {
    use crossfont::Size;

    use super::ui_config::Delta;

    #[derive(Debug, Clone, PartialEq, Eq)]
    pub struct Font {
        pub offset: Delta<i8>,
        pub glyph_offset: Delta<i8>,
        pub builtin_box_drawing: bool,
        normal: FontDescription,
        bold: SecondaryFontDescription,
        italic: SecondaryFontDescription,
        bold_italic: SecondaryFontDescription,
        size: Size,
    }

    impl Font {
        pub fn new(family: String, size: Size) -> Self {
            Self {
                offset: Delta::default(),
                glyph_offset: Delta::default(),
                builtin_box_drawing: true,
                normal: FontDescription {
                    family,
                    style: None,
                },
                bold: SecondaryFontDescription::default(),
                italic: SecondaryFontDescription::default(),
                bold_italic: SecondaryFontDescription::default(),
                size,
            }
        }

        pub fn size(&self) -> Size {
            self.size
        }

        pub fn normal(&self) -> &FontDescription {
            &self.normal
        }

        pub fn bold(&self) -> FontDescription {
            self.bold.desc(&self.normal)
        }

        pub fn italic(&self) -> FontDescription {
            self.italic.desc(&self.normal)
        }

        pub fn bold_italic(&self) -> FontDescription {
            self.bold_italic.desc(&self.normal)
        }
    }

    impl Default for Font {
        fn default() -> Self {
            Self::new(String::from("Menlo"), Size::new(11.25))
        }
    }

    #[derive(Debug, Clone, PartialEq, Eq)]
    pub struct FontDescription {
        pub family: String,
        pub style: Option<String>,
    }

    #[derive(Debug, Default, Clone, PartialEq, Eq)]
    struct SecondaryFontDescription {
        family: Option<String>,
        style: Option<String>,
    }

    impl SecondaryFontDescription {
        fn desc(&self, fallback: &FontDescription) -> FontDescription {
            FontDescription {
                family: self
                    .family
                    .clone()
                    .unwrap_or_else(|| fallback.family.clone()),
                style: self.style.clone(),
            }
        }
    }
}
