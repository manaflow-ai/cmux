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
    /// The column's rows top to bottom (`rows-v1`); `None` for a column
    /// with one row. Row 2..n's `row_id` is its compat chain split in
    /// `root`. In `workspace.layout.apply` `None` keeps the stored rows and
    /// an empty list leaves the column one row.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub rows: Option<Vec<LayoutRow>>,
}

/// One row of a column (catalog `LayoutRow`, `rows-v1`): its stable id and
/// its height in permille of the column's viewport height (100 to 1000).
/// Only row 1 may omit `row_id`, in a document sent to
/// `workspace.layout.apply`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct LayoutRow {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub row_id: Option<SplitId>,
    pub height: u16,
}

impl<'de> Deserialize<'de> for LayoutRow {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        #[derive(Deserialize)]
        #[serde(deny_unknown_fields)]
        struct Wire {
            #[serde(default)]
            row_id: Option<SplitId>,
            height: u16,
        }

        let wire = Wire::deserialize(deserializer)?;
        if !(100..=1000).contains(&wire.height) {
            return Err(serde::de::Error::custom("layout row height must be from 100 to 1000"));
        }
        Ok(Self { row_id: wire.row_id, height: wire.height })
    }
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
            // `sticky` is the pre-R87 name: a replayed or older result
            // still decodes.
            #[serde(default, alias = "sticky", deserialize_with = "deserialize_nullable")]
            dock: Option<LayoutColumnDock>,
            #[serde(default)]
            rows: Option<Vec<LayoutRow>>,
        }

        let wire = Wire::deserialize(deserializer)?;
        if !wire.width.is_finite() || !(0.1..=1.0).contains(&wire.width) {
            return Err(serde::de::Error::custom(
                "layout column width must be finite and between 0.1 and 1",
            ));
        }
        Ok(Self {
            column_id: wire.column_id,
            width: wire.width,
            root: wire.root,
            dock: wire.dock,
            rows: wire.rows,
        })
    }
}
