use std::cmp;

use alacritty_terminal::grid::Dimensions;
use alacritty_terminal::index::Point;
use alacritty_terminal::term::cell::Flags;

pub mod color {
    #[derive(Copy, Clone, Debug, Default, Eq, PartialEq)]
    pub struct Rgb {
        pub r: u8,
        pub g: u8,
        pub b: u8,
    }

    impl Rgb {
        pub const fn new(r: u8, g: u8, b: u8) -> Self {
            Self { r, g, b }
        }

        pub const fn as_tuple(self) -> (u8, u8, u8) {
            (self.r, self.g, self.b)
        }
    }
}

pub mod content {
    use super::{Flags, Point};
    use crate::display::color::Rgb;

    #[derive(Clone, Debug)]
    pub struct RenderableCell {
        pub character: char,
        pub point: Point<usize>,
        pub fg: Rgb,
        pub bg: Rgb,
        pub bg_alpha: f32,
        pub underline: Rgb,
        pub flags: Flags,
        pub extra: Option<Box<RenderableCellExtra>>,
    }

    #[derive(Clone, Debug)]
    pub struct RenderableCellExtra {
        pub zerowidth: Option<Vec<char>>,
    }
}

const MIN_COLUMNS: usize = 2;
const MIN_SCREEN_LINES: usize = 1;

#[derive(Debug, Copy, Clone, PartialEq)]
pub struct SizeInfo {
    width: f32,
    height: f32,
    cell_width: f32,
    cell_height: f32,
    padding_x: f32,
    padding_y: f32,
    screen_lines: usize,
    columns: usize,
}

impl SizeInfo {
    pub fn new(
        width: f32,
        height: f32,
        cell_width: f32,
        cell_height: f32,
        padding_x: f32,
        padding_y: f32,
    ) -> Self {
        let screen_lines =
            cmp::max(((height - 2.0 * padding_y) / cell_height) as usize, MIN_SCREEN_LINES);
        let columns =
            cmp::max(((width - 2.0 * padding_x) / cell_width) as usize, MIN_COLUMNS);
        Self {
            width,
            height,
            cell_width,
            cell_height,
            padding_x: padding_x.floor(),
            padding_y: padding_y.floor(),
            screen_lines,
            columns,
        }
    }

    pub fn width(&self) -> f32 {
        self.width
    }

    pub fn height(&self) -> f32 {
        self.height
    }

    pub fn cell_width(&self) -> f32 {
        self.cell_width
    }

    pub fn cell_height(&self) -> f32 {
        self.cell_height
    }

    pub fn padding_x(&self) -> f32 {
        self.padding_x
    }

    pub fn padding_y(&self) -> f32 {
        self.padding_y
    }
}

impl Dimensions for SizeInfo {
    fn total_lines(&self) -> usize {
        self.screen_lines
    }

    fn screen_lines(&self) -> usize {
        self.screen_lines
    }

    fn columns(&self) -> usize {
        self.columns
    }
}
