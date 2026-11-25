//! One viewport column of a layout document and its dock flag.

use super::*;
use crate::resource::handles::state_ops::{ColumnEdge, ColumnMode};

/// One stable horizontal viewport column.
#[derive(Clone, Debug, PartialEq, Serialize)]
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

/// What a docked column holds (catalog `LayoutColumnDock.role`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ColumnRole {
    /// The agent chat dock of the workspace.
    AgentChat,
}

impl ColumnRole {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::AgentChat => "agent_chat",
        }
    }
}

/// A docked column's edge, presentation, role and flags (catalog
/// `LayoutColumnDock`). The type names each member of the catalog type: the
/// layout of a screen is in each session snapshot, and a document that is
/// read and then sent to `workspace.layout.apply` keeps each member.
#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq, Serialize)]
pub struct LayoutColumnDock {
    pub edge: ColumnEdge,
    pub mode: ColumnMode,
    /// What the column holds; `None` for a plain dock.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub role: Option<ColumnRole>,
    /// The dock cannot be undocked or closed. Omitted when false.
    #[serde(default, skip_serializing_if = "is_false")]
    pub permanent: bool,
    /// The column is a pinned column (`pinned-dock-v1`). Omitted when false.
    #[serde(default, skip_serializing_if = "is_false")]
    pub pinned: bool,
    /// A pinned column takes more tabs (`pinned-dock-v1`). Omitted when
    /// false.
    #[serde(default, skip_serializing_if = "is_false")]
    pub allow_tabs: bool,
}

impl LayoutColumnDock {
    /// A plain dock: no role and no flag.
    pub const fn new(edge: ColumnEdge, mode: ColumnMode) -> Self {
        Self { edge, mode, role: None, permanent: false, pinned: false, allow_tabs: false }
    }
}

fn is_false(value: &bool) -> bool {
    !*value
}

impl<'de> Deserialize<'de> for LayoutColumn {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        #[derive(Deserialize)]
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
