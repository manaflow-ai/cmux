//! `column.update` on a screen handle: pin, unpin, or resize one viewport
//! column.

use super::*;

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
        if options.sticky.is_none() && options.width.is_none() {
            return Err(Error::InvalidArgument(
                "column update must set sticky, width, or both".to_string(),
            ));
        }
        let mut params = self
            .params()
            .string("column", column)
            .optional_bool("sticky", options.sticky)
            .optional_string("edge", options.edge)
            .optional_string("mode", options.mode);
        if let Some(width) = options.width {
            let width = serde_json::Number::from_f64(width)
                .ok_or_else(|| Error::InvalidArgument("column width must be finite".to_string()))?;
            params = params.value("width", Value::Number(width));
        }
        mutation_snapshot(
            self.workspace.session.client.mutate(ops::SCREEN_COLUMN_UPDATE, params, mutation)?,
            "screen",
        )
    }
}
