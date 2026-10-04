//! `column.update` on a screen handle: pin, unpin, or resize one viewport
//! column.

use super::super::*;

/// Viewport edge of a sticky column (`column.update` `edge`). `Top` and
/// `Bottom` are the edge docks of `edge-docks-v1`: the column becomes a
/// screen-wide band rather than a sticky side column.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum ColumnEdge {
    Left,
    Right,
    Top,
    Bottom,
}

impl ColumnEdge {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Left => "left",
            Self::Right => "right",
            Self::Top => "top",
            Self::Bottom => "bottom",
        }
    }
}

/// Presentation of a sticky column (`column.update` `mode`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum ColumnMode {
    Docked,
    Overlay,
}

impl ColumnMode {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Docked => "docked",
            Self::Overlay => "overlay",
        }
    }
}

impl ColumnUpdateOptions {
    /// Pins the column to `edge` with presentation `mode`.
    pub fn pin(edge: ColumnEdge, mode: ColumnMode) -> Self {
        Self {
            sticky: Some(true),
            edge: Some(edge.as_str().to_string()),
            mode: Some(mode.as_str().to_string()),
            width: None,
        }
    }

    /// Unpins the column; it scrolls again.
    pub fn unpin() -> Self {
        Self { sticky: Some(false), edge: None, mode: None, width: None }
    }

    /// Sets the column width as a fraction of the viewport (0.1 to 1).
    pub fn width(width: f64) -> Self {
        Self { sticky: None, edge: None, mode: None, width: Some(width) }
    }

    fn validate(&self) -> Result<()> {
        let invalid = |message: &str| Err(Error::InvalidArgument(message.to_string()));
        if self.sticky.is_none() && self.width.is_none() {
            return invalid("column update must set sticky, width, or both");
        }
        if self.sticky != Some(true) && (self.edge.is_some() || self.mode.is_some()) {
            return invalid("column update edge and mode apply only with sticky: true");
        }
        if self
            .edge
            .as_deref()
            .is_some_and(|edge| !matches!(edge, "left" | "right" | "top" | "bottom"))
        {
            return invalid("column edge must be left, right, top or bottom");
        }
        if self.mode.as_deref().is_some_and(|mode| !matches!(mode, "docked" | "overlay")) {
            return invalid("column mode must be docked or overlay");
        }
        if self.width.is_some_and(|width| !width.is_finite() || !(0.1..=1.0).contains(&width)) {
            return invalid("column width must be finite and between 0.1 and 1");
        }
        Ok(())
    }
}

impl Screen {
    /// Pins, unpins, or resizes the viewport column `column` (its split ID)
    /// with a fresh idempotency key.
    pub fn update_column(
        &self,
        column: impl Into<String>,
        options: ColumnUpdateOptions,
    ) -> Result<MutationResult<ScreenSnapshot>> {
        self.update_column_with(column, options, MutationOptions::unique()?)
    }

    pub fn update_column_with(
        &self,
        column: impl Into<String>,
        options: ColumnUpdateOptions,
        mutation: MutationOptions,
    ) -> Result<MutationResult<ScreenSnapshot>> {
        options.validate()?;
        let params = self
            .params()
            .string("column", column)
            .optional_bool("sticky", options.sticky)
            .optional_string("edge", options.edge)
            .optional_string("mode", options.mode)
            .optional_f64("width", options.width);
        mutation_snapshot(
            self.workspace.session.client.mutate(ops::SCREEN_COLUMN_UPDATE, params, mutation)?,
            "screen",
        )
    }
}
