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
            // `sticky` is the pre-R87 name: a replayed or older result
            // still decodes.
            #[serde(default, alias = "sticky", deserialize_with = "deserialize_nullable")]
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

#[cfg(test)]
mod tests {
    use super::LayoutColumn;

    fn column(flag: &str) -> LayoutColumn {
        serde_json::from_str(&format!(
            r#"{{"column_id":"split_00000000000000000000000000000008","width":0.5,
                "root":{{"kind":"leaf","pane_id":"pane_00000000000000000000000000000005","tab_ids":[]}}{flag}}}"#
        ))
        .unwrap()
    }

    /// R87: `sticky`, the pre-rename name of `dock`, still decodes (replayed
    /// mutation results, older daemons); a new document writes `dock`.
    #[test]
    fn a_legacy_sticky_flag_decodes_as_dock() {
        let legacy = column(r#","sticky":{"edge":"left","mode":"overlay"}"#);
        let current = column(r#","dock":{"edge":"left","mode":"overlay"}"#);
        assert_eq!(legacy, current);
        assert!(current.dock.is_some());
        let written = serde_json::to_value(&legacy).unwrap();
        assert_eq!(written["dock"], serde_json::json!({"edge": "left", "mode": "overlay"}));
        assert!(written.get("sticky").is_none());
    }
}
