//! One viewport column of a layout document and its dock flag.

use super::*;
use crate::resource::handles::state_ops::{ColumnEdge, ColumnMode};

/// One stable horizontal viewport column.
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct LayoutColumn {
    pub column_id: SplitId,
    pub width: f64,
    pub root: Box<LayoutNode>,
    /// The column's dock flag (`dock-columns-v1`); `None` while it
    /// scrolls. In `workspace.layout.apply` an omitted flag keeps the stored
    /// one.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub dock: Option<LayoutColumnDock>,
}

/// A pinned column's edge and presentation (catalog `LayoutColumnDock`).
#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct LayoutColumnDock {
    pub edge: ColumnEdge,
    pub mode: ColumnMode,
}

impl<'de> Deserialize<'de> for LayoutColumn {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        #[derive(Deserialize)]
        #[serde(deny_unknown_fields)]
        struct Wire {
            column_id: SplitId,
            width: f64,
            root: Box<LayoutNode>,
            #[serde(default, deserialize_with = "deserialize_nullable")]
            dock: Option<LayoutColumnDock>,
        }

        let wire = Wire::deserialize(deserializer)?;
        if !wire.width.is_finite() || !(0.1..=1.0).contains(&wire.width) {
            return Err(serde::de::Error::custom(
                "layout column width must be finite and between 0.1 and 1",
            ));
        }
        Ok(Self { column_id: wire.column_id, width: wire.width, root: wire.root, dock: wire.dock })
    }
}

