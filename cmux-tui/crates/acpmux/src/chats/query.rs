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
    /// Where the page starts (the `nextCursor` of the last page).
    pub cursor: ChatCursor,
}

/// Where a page of chats starts. A `nextCursor` names the last chat its page held, so a chat that
/// moves to the top or leaves meanwhile neither repeats nor skips a chat on the next page; a bare
/// number is an offset, as cursors were before.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum ChatCursor {
    #[default]
    Start,
    Offset(usize),
    /// After the chat last used at `updated_ms` whose key hashes to `key`.
    After {
        updated_ms: i64,
        key: u64,
    },
}

impl ChatCursor {
    /// The cursor after `chat`: `k<updatedMs hex>.<key hash hex>`, at most 30 characters (the app
    /// passes at most 32).
    pub fn after(chat: &IndexedChat) -> Self {
        Self::After { updated_ms: stamp(chat), key: key_hash(chat) }
    }

    pub fn to_text(self) -> String {
        match self {
            Self::Start => "0".to_owned(),
            Self::Offset(n) => n.to_string(),
            Self::After { updated_ms, key } => format!("k{updated_ms:x}.{key:016x}"),
        }
    }

    fn parse(text: &str) -> Option<Self> {
        if let Some(rest) = text.strip_prefix('k') {
            let (updated, key) = rest.split_once('.')?;
            let updated_ms = i64::from_str_radix(updated, 16).ok()?;
            return Some(Self::After { updated_ms, key: u64::from_str_radix(key, 16).ok()? });
        }
        text.parse().ok().map(Self::Offset)
    }

    /// Where the page starts in `chats` (the matching chats, newest first). The named chat gone or
    /// moved, the page starts at the first chat no newer than it was: a chat last used in that same
    /// millisecond may repeat, none is skipped.
    pub fn start(self, chats: &[&IndexedChat]) -> usize {
        match self {
            Self::Start => 0,
            Self::Offset(n) => n,
            Self::After { updated_ms, key } => chats
                .iter()
                .position(|chat| stamp(chat) == updated_ms && key_hash(chat) == key)
                .map(|at| at + 1)
                .unwrap_or_else(|| {
                    chats.iter().position(|chat| stamp(chat) <= updated_ms).unwrap_or(chats.len())
                }),
        }
    }
}

/// The chat's time as a cursor holds it: a store's time before 1970 or past year 10889 (bad data)
/// is clamped, so the cursor stays short and still finds the chat it names.
fn stamp(chat: &IndexedChat) -> i64 {
    chat.entry.updated_ms.clamp(0, 0xffff_ffff_ffff)
}

/// FNV-1a of the chat's key text (`<harness id>:<session id>`): the same in every daemon run.
fn key_hash(chat: &IndexedChat) -> u64 {
    let entry = &chat.entry;
    let text = format!("{}:{}", entry.harness.id(), entry.session_id);
    text.bytes().fold(0xcbf2_9ce4_8422_2325, |hash, byte| {
        (hash ^ u64::from(byte)).wrapping_mul(0x0100_0000_01b3)
    })
}

impl Default for ChatQuery {
    fn default() -> Self {
        Self {
            text: None,
            harness: None,
            folder: None,
            account: None,
            limit: Self::DEFAULT_LIMIT,
            cursor: ChatCursor::Start,
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
            None => ChatCursor::Start,
            Some(c) => {
                ChatCursor::parse(&c).ok_or_else(|| format!("cursor {c:?} is not a cursor"))?
            }
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
