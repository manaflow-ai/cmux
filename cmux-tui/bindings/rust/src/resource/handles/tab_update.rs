//! `tab.pin`, `tab.unpin`, and `tab.update` on a tab handle. The result's
//! `TabSnapshot.extra` carries `pinned`, `zoom`, a browser tab's `back` and
//! `forward` URL lists, a frontend-rendered browser's `owner`, and the
//! user's `icon`.

use super::super::*;

/// Most URLs `tab.update` accepts in `back` or `forward`.
pub const TAB_HISTORY_MAX_URLS: usize = 20;

/// Fields of `tab.update`. At least one field must be present. `back` and
/// `forward` apply only to browser tabs; `owner` only to frontend-rendered
/// browser tabs.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct TabUpdateOptions {
    /// Browser page zoom or terminal font scale, 0.25 to 5. `Update::Clear`
    /// sends `null`.
    pub zoom: Update<f64>,
    /// A browser tab's back URLs, oldest first, at most 20.
    pub back: Option<Vec<String>>,
    /// A browser tab's forward URLs, nearest first, at most 20.
    pub forward: Option<Vec<String>>,
    /// Install id of the app that hosts a frontend-rendered browser tab,
    /// 1 to 128 bytes. Only that app sends it.
    pub owner: Option<String>,
    /// The tab's user icon: an SF Symbol name or one emoji (the daemon
    /// validates the shape). `Update::Clear` sends `null`.
    pub icon: Update<String>,
}

impl Tab {
    /// Pins the tab with a fresh idempotency key. Pinned tabs sort first in
    /// their pane and leave any tab group.
    pub fn pin(&self) -> Result<MutationResult<TabSnapshot>> {
        self.pin_with(MutationOptions::unique()?)
    }

    pub fn pin_with(&self, mutation: MutationOptions) -> Result<MutationResult<TabSnapshot>> {
        mutation_snapshot(self.client().mutate(ops::TAB_PIN, self.params(), mutation)?, "tab")
    }

    /// Unpins the tab with a fresh idempotency key.
    pub fn unpin(&self) -> Result<MutationResult<TabSnapshot>> {
        self.unpin_with(MutationOptions::unique()?)
    }

    pub fn unpin_with(&self, mutation: MutationOptions) -> Result<MutationResult<TabSnapshot>> {
        mutation_snapshot(self.client().mutate(ops::TAB_UNPIN, self.params(), mutation)?, "tab")
    }

    /// Sets the tab's zoom, browser history lists, frontend owner, or icon
    /// with a fresh idempotency key.
    pub fn update(&self, options: TabUpdateOptions) -> Result<MutationResult<TabSnapshot>> {
        self.update_with(options, MutationOptions::unique()?)
    }

    pub fn update_with(
        &self,
        options: TabUpdateOptions,
        mutation: MutationOptions,
    ) -> Result<MutationResult<TabSnapshot>> {
        let params = tab_update_params(self.params(), options)?;
        mutation_snapshot(self.client().mutate(ops::TAB_UPDATE, params, mutation)?, "tab")
    }

    fn client(&self) -> &Client {
        &self.pane.screen.workspace.session.client
    }
}

fn tab_update_params(params: Params, options: TabUpdateOptions) -> Result<Params> {
    let TabUpdateOptions { zoom, back, forward, owner, icon } = options;
    if matches!(zoom, Update::Unchanged)
        && matches!(icon, Update::Unchanged)
        && back.is_none()
        && forward.is_none()
        && owner.is_none()
    {
        return Err(Error::InvalidArgument(
            "tab update must set zoom, back, forward, owner, or icon".to_string(),
        ));
    }
    let mut params = match zoom {
        Update::Unchanged => params,
        Update::Clear => params.value("zoom", Value::Null),
        Update::Set(zoom) if zoom.is_finite() && (0.25..=5.0).contains(&zoom) => {
            params.f64("zoom", zoom)
        }
        Update::Set(_) => {
            return Err(Error::InvalidArgument(
                "tab zoom must be finite and between 0.25 and 5".to_string(),
            ));
        }
    };
    for (key, urls) in [("back", back), ("forward", forward)] {
        let Some(urls) = urls else { continue };
        if urls.len() > TAB_HISTORY_MAX_URLS {
            return Err(Error::InvalidArgument(format!(
                "tab {key} holds at most {TAB_HISTORY_MAX_URLS} URLs"
            )));
        }
        params = params.value(key, Value::Array(urls.into_iter().map(Value::String).collect()));
    }
    if let Some(owner) = owner {
        if owner.is_empty() || owner.len() > 128 {
            return Err(Error::InvalidArgument(
                "tab owner must contain 1 to 128 bytes".to_string(),
            ));
        }
        params = params.string("owner", owner);
    }
    match icon {
        Update::Unchanged => {}
        Update::Clear => params = params.value("icon", Value::Null),
        Update::Set(icon) if !icon.is_empty() && icon.len() <= 128 => {
            params = params.string("icon", icon);
        }
        Update::Set(_) => {
            return Err(Error::InvalidArgument("tab icon must contain 1 to 128 bytes".to_string()));
        }
    }
    Ok(params)
}
