//! Tab snapshots: the content kind (terminal, browser, conversation) and the
//! typed content ID it decodes.

use super::*;

/// Kind of resource hosted by a tab.
#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum TabContentKind {
    Terminal,
    Browser,
    /// A tab showing one conversation (`extra.conversation`). Its content
    /// ID is a browser ID that no browser operation accepts. Only a
    /// connection that declared `CONVERSATION_TABS_CAPABILITY` reads it;
    /// others read `Browser`.
    Conversation,
}

/// Typed content ID hosted by a tab. A conversation tab's content ID is a
/// `Browser` ID.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum TabContentId {
    Terminal(TerminalId),
    Browser(BrowserId),
}

/// Catalog snapshot for one tab.
#[derive(Clone, Debug, PartialEq)]
pub struct TabSnapshot {
    pub id: TabId,
    pub pane_id: PaneId,
    pub name: Option<String>,
    pub index: u32,
    pub focused: bool,
    pub content_kind: TabContentKind,
    pub content_id: TabContentId,
    pub extra: BTreeMap<String, Value>,
}

impl<'de> Deserialize<'de> for TabSnapshot {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        #[derive(Deserialize)]
        #[serde(deny_unknown_fields)]
        struct Wire {
            id: TabId,
            pane_id: PaneId,
            #[serde(deserialize_with = "deserialize_nullable")]
            name: Option<String>,
            index: u32,
            focused: bool,
            content_kind: TabContentKind,
            content_id: String,
            #[serde(default)]
            extra: BTreeMap<String, Value>,
        }

        let wire = Wire::deserialize(deserializer)?;
        let content_id = match wire.content_kind {
            TabContentKind::Terminal => {
                TerminalId::parse(wire.content_id).map(TabContentId::Terminal)
            }
            TabContentKind::Browser | TabContentKind::Conversation => {
                BrowserId::parse(wire.content_id).map(TabContentId::Browser)
            }
        }
        .map_err(serde::de::Error::custom)?;
        Ok(Self {
            id: wire.id,
            pane_id: wire.pane_id,
            name: wire.name,
            index: wire.index,
            focused: wire.focused,
            content_kind: wire.content_kind,
            content_id,
            extra: wire.extra,
        })
    }
}
