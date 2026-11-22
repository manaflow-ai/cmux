//! The filter of `_acpmux/chats` and `_acpmux/chats_watch`.

use cmux_chat_index::{AdapterKind, IndexedChat};
use serde_json::Value;

/// `{query, harness, folder, account, limit, cursor}`; every field optional.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ChatQuery {
    /// Case-insensitive text in the title or the folder.
    pub text: Option<String>,
    pub harness: Option<AdapterKind>,
    /// The folder or a folder inside it.
    pub folder: Option<String>,
    pub account: Option<String>,
    pub limit: usize,
    /// How many matching chats to skip (the `nextCursor` of the last page).
    pub cursor: usize,
}

impl Default for ChatQuery {
    fn default() -> Self {
        Self {
            text: None,
            harness: None,
            folder: None,
            account: None,
            limit: Self::DEFAULT_LIMIT,
            cursor: 0,
        }
    }
}

impl ChatQuery {
    pub const DEFAULT_LIMIT: usize = 200;
    pub const MAX_LIMIT: usize = 5000;

    pub fn from_params(params: &Value) -> Result<Self, String> {
        let text_of = |key: &str| -> Result<Option<String>, String> {
            match params.get(key) {
                None | Some(Value::Null) => Ok(None),
                Some(Value::String(s)) if s.is_empty() => Ok(None),
                Some(Value::String(s)) => Ok(Some(s.clone())),
                Some(_) => Err(format!("{key} must be a string")),
            }
        };
        let harness = match text_of("harness")? {
            None => None,
            Some(id) => Some(AdapterKind::from_id(&id).ok_or_else(|| {
                let known: Vec<&str> = AdapterKind::ALL.iter().map(|kind| kind.id()).collect();
                format!("harness {id:?} is unknown; use one of {}", known.join(", "))
            })?),
        };
        let limit = match params.get("limit") {
            None | Some(Value::Null) => Self::DEFAULT_LIMIT,
            Some(v) => {
                let n = v.as_u64().ok_or("limit must be a positive number")?;
                usize::try_from(n).unwrap_or(usize::MAX).clamp(1, Self::MAX_LIMIT)
            }
        };
        let cursor = match text_of("cursor")? {
            None => 0,
            Some(c) => c.parse().map_err(|_| format!("cursor {c:?} is not a cursor"))?,
        };
        Ok(Self {
            text: text_of("query")?.map(|q| q.to_lowercase()),
            harness,
            folder: text_of("folder")?.map(|f| f.trim_end_matches('/').to_owned()),
            account: text_of("account")?,
            limit,
            cursor,
        })
    }

    pub fn matches(&self, chat: &IndexedChat) -> bool {
        let entry = &chat.entry;
        if self.harness.is_some_and(|harness| harness != entry.harness) {
            return false;
        }
        if let Some(account) = &self.account
            && !chat.accounts.contains(account)
        {
            return false;
        }
        if let Some(folder) = &self.folder {
            let Some(cwd) = entry.cwd.as_deref() else { return false };
            let cwd = cwd.trim_end_matches('/');
            if cwd != folder && !cwd.starts_with(&format!("{folder}/")) {
                return false;
            }
        }
        if let Some(text) = &self.text {
            let hit = |field: Option<&str>| field.is_some_and(|f| f.to_lowercase().contains(text));
            if !hit(entry.title.as_deref()) && !hit(entry.cwd.as_deref()) {
                return false;
            }
        }
        true
    }
}
