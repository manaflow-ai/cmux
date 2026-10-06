//! Typed frontend-rendered browser tabs on the raw protocol-v12 client:
//! `new-frontend-browser-tab` with an idempotency key
//! (`frontend-browser-tab-keys-v1`) and `update-frontend-browser-tab`.
//!
//! The app that renders the page (WebKit or CEF) creates the tab and writes
//! its location back; the daemon stores the record and never attaches a CDP
//! target. Both commands address the legacy numeric pane and surface ids of
//! the raw tree.

use crate::generated::{
    IdentifyRequest, NewFrontendBrowserTabRequest, UpdateFrontendBrowserTabRequest,
};
use crate::resource::{BrowserId, TabId, Update, validate_idempotency_key};
use crate::{CmuxClient, Error, Optional, Result};
use serde_json::Value;

/// The daemon dedupes `new-frontend-browser-tab` by `idempotency_key`.
pub const FRONTEND_BROWSER_TAB_KEYS_CAPABILITY: &str = "frontend-browser-tab-keys-v1";

/// Renderer of a frontend browser tab.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum FrontendBrowserEngine {
    Webkit,
    Cef,
}

impl FrontendBrowserEngine {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Webkit => "webkit",
            Self::Cef => "cef",
        }
    }
}

/// A keyed `new-frontend-browser-tab`. Reuse the same `idempotency_key` (and
/// the same fields) only to retry a create whose reply was lost: the daemon
/// then returns the first tab with `replayed: true`. The same key with other
/// fields fails and creates nothing.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FrontendBrowserTabCreate {
    pub url: String,
    pub engine: FrontendBrowserEngine,
    /// Legacy pane id; `None` is the active pane.
    pub pane: Option<u64>,
    pub title: Option<String>,
    pub favicon_url: Option<String>,
    pub profile_id: Option<String>,
    /// Install id of the hosting app, the record's only writer.
    pub owner: Option<String>,
    /// Initial size hint in cells (`cols`, `rows`).
    pub size: Option<(u16, u16)>,
    pub idempotency_key: String,
}

impl FrontendBrowserTabCreate {
    pub fn new(
        url: impl Into<String>,
        engine: FrontendBrowserEngine,
        idempotency_key: impl Into<String>,
    ) -> Self {
        Self {
            url: url.into(),
            engine,
            pane: None,
            title: None,
            favicon_url: None,
            profile_id: None,
            owner: None,
            size: None,
            idempotency_key: idempotency_key.into(),
        }
    }
}

/// The created (or, on a retry, the first) frontend browser tab.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FrontendBrowserTabCreated {
    /// Legacy surface id (`update-frontend-browser-tab` addresses it).
    pub surface: u64,
    pub tab_id: TabId,
    pub browser_id: BrowserId,
    /// True when the daemon returned the tab of an earlier request with the
    /// same key.
    pub replayed: bool,
}

/// `update-frontend-browser-tab`: the location the page reports. `None`
/// leaves a field unchanged; `favicon_url: Update::Clear` clears the favicon.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct FrontendBrowserTabUpdate {
    pub surface: u64,
    pub url: Option<String>,
    pub title: Option<String>,
    pub favicon_url: Update<String>,
    pub owner: Option<String>,
}

/// The stored record after `update-frontend-browser-tab`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FrontendBrowserTabUpdated {
    pub surface: u64,
    pub url: String,
    pub title: Option<String>,
    pub favicon_url: Option<String>,
    pub owner: Option<String>,
    /// False when the record already held these values.
    pub changed: bool,
}

impl CmuxClient {
    /// Creates a frontend-rendered browser tab, deduped by its idempotency
    /// key. Identifies the connection first when it has not, and fails with
    /// `MissingCapability` before sending anything to a daemon without
    /// `frontend-browser-tab-keys-v1` (which would ignore the key).
    pub fn create_frontend_browser_tab(
        &mut self,
        create: FrontendBrowserTabCreate,
    ) -> Result<FrontendBrowserTabCreated> {
        validate_idempotency_key(&create.idempotency_key)?;
        if self.server_info().is_none() {
            self.identify(IdentifyRequest {})?;
        }
        self.require_capability_field(
            "new-frontend-browser-tab",
            FRONTEND_BROWSER_TAB_KEYS_CAPABILITY,
        )?;
        let (cols, rows) = create.size.map_or((None, None), |(c, r)| (Some(c), Some(r)));
        let result = self.new_frontend_browser_tab(NewFrontendBrowserTabRequest {
            url: create.url,
            engine: create.engine.as_str().to_string(),
            pane: optional(create.pane),
            title: optional(create.title),
            favicon_url: optional(create.favicon_url),
            profile_id: optional(create.profile_id),
            owner: optional(create.owner),
            idempotency_key: Optional::Value(create.idempotency_key),
            cols: optional(cols),
            rows: optional(rows),
            activate: None,
        })?;
        let created = || -> Option<FrontendBrowserTabCreated> {
            Some(FrontendBrowserTabCreated {
                surface: result.get("surface")?.as_u64()?,
                tab_id: TabId::parse(result.get("tab_resource_id")?.as_str()?).ok()?,
                browser_id: BrowserId::parse(result.get("content_resource_id")?.as_str()?).ok()?,
                replayed: result.get("replayed")?.as_bool()?,
            })
        };
        created().ok_or_else(|| decode_error("new-frontend-browser-tab", &result))
    }

    /// Records the URL, title, favicon, or owner a frontend-rendered page
    /// reports.
    pub fn write_frontend_browser_tab(
        &mut self,
        update: FrontendBrowserTabUpdate,
    ) -> Result<FrontendBrowserTabUpdated> {
        let result = self.update_frontend_browser_tab(UpdateFrontendBrowserTabRequest {
            surface: update.surface,
            url: optional(update.url),
            title: optional(update.title),
            favicon_url: match update.favicon_url {
                Update::Unchanged => Optional::Missing,
                Update::Clear => Optional::Null,
                Update::Set(url) => Optional::Value(url),
            },
            owner: optional(update.owner),
        })?;
        let text = |key: &str| result.get(key).and_then(Value::as_str).map(str::to_string);
        let updated = || -> Option<FrontendBrowserTabUpdated> {
            Some(FrontendBrowserTabUpdated {
                surface: result.get("surface")?.as_u64()?,
                url: text("url")?,
                title: text("title"),
                favicon_url: text("favicon_url"),
                owner: text("owner"),
                changed: result.get("changed")?.as_bool()?,
            })
        };
        updated().ok_or_else(|| decode_error("update-frontend-browser-tab", &result))
    }
}

fn optional<T>(value: Option<T>) -> Optional<T> {
    value.map_or(Optional::Missing, Optional::Value)
}

fn decode_error(command: &str, result: &Value) -> Error {
    Error::Decode(format!("{command} result is not the documented object: {result}"))
}
