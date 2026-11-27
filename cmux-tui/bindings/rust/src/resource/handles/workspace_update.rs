//! `workspace.update` on a workspace handle: the shared title, color, and
//! icon (`WorkspaceSnapshot.extra`); and `workspace.agent_folder.set`, the
//! folder new agent chats start in (`extra.agent_folder`); and
//! `workspace.open_url`, a web link on the workspace's right side.

use super::super::*;

/// Fields of `workspace.update`. `Update::Unchanged` omits a field,
/// `Update::Clear` sends `null` (clears it), and `Update::Set` sets it.
/// At least one field must change.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct WorkspaceUpdateOptions {
    /// Custom title.
    pub title: Update<String>,
    /// Palette token or `#RRGGBB[AA]`.
    pub color: Update<String>,
    /// SF Symbol name or one emoji.
    pub icon: Update<String>,
}

impl Workspace {
    /// Sets or clears the workspace's title, color, or icon with a fresh
    /// idempotency key.
    pub fn update(
        &self,
        options: WorkspaceUpdateOptions,
    ) -> Result<MutationResult<WorkspaceSnapshot>> {
        self.update_with(options, MutationOptions::unique()?)
    }

    pub fn update_with(
        &self,
        options: WorkspaceUpdateOptions,
        mutation: MutationOptions,
    ) -> Result<MutationResult<WorkspaceSnapshot>> {
        let WorkspaceUpdateOptions { title, color, icon } = options;
        if [&title, &color, &icon].iter().all(|field| matches!(field, Update::Unchanged)) {
            return Err(Error::InvalidArgument(
                "workspace update must change title, color, or icon".to_string(),
            ));
        }
        let params = nullable_string(self.params(), field::TITLE, title);
        let params = nullable_string(params, "color", color);
        let params = nullable_string(params, "icon", icon);
        mutation_snapshot(
            self.session.client.mutate(ops::WORKSPACE_UPDATE, params, mutation)?,
            "workspace",
        )
    }
}

impl Workspace {
    /// Sets (`Some`) or clears (`None`) the folder new agent chats of the
    /// workspace start in, with a fresh idempotency key. The daemon accepts
    /// it only from a verified cmux app (origin `user`), and only an
    /// absolute, existing, canonical directory.
    pub fn set_agent_folder(
        &self,
        path: Option<String>,
    ) -> Result<MutationResult<WorkspaceSnapshot>> {
        self.set_agent_folder_with(path, MutationOptions::unique()?)
    }

    pub fn set_agent_folder_with(
        &self,
        path: Option<String>,
        mutation: MutationOptions,
    ) -> Result<MutationResult<WorkspaceSnapshot>> {
        if path.as_deref().is_some_and(|path| !path.starts_with('/')) {
            return Err(Error::InvalidArgument(
                "agent folder must be an absolute path".to_string(),
            ));
        }
        let params = match path {
            Some(path) => self.params().string("path", path),
            None => self.params().value("path", Value::Null),
        };
        mutation_snapshot(
            self.session.client.mutate(ops::WORKSPACE_AGENT_FOLDER_SET, params, mutation)?,
            "workspace",
        )
    }
}

impl Workspace {
    /// Opens an http(s) link on the workspace's right side
    /// (`workspace-open-url-v1`) with a fresh idempotency key: the browser
    /// tab the person looked at last navigates to it, else a new browser tab
    /// opens; never in the agent chat dock, and the keyboard focus stays.
    /// The value is `{kind, workspace_id, screen_id, pane_id, tab_id,
    /// browser_id, reused}`.
    pub fn open_url(&self, url: impl Into<String>) -> Result<MutationResult<Value>> {
        self.open_url_with(url, MutationOptions::unique()?)
    }

    pub fn open_url_with(
        &self,
        url: impl Into<String>,
        mutation: MutationOptions,
    ) -> Result<MutationResult<Value>> {
        let params = self.params().string("url", url.into());
        mutation_result(
            self.session.client.mutate(ops::WORKSPACE_OPEN_URL, params, mutation)?,
            |value| Ok(value.clone()),
        )
    }
}

/// An omitted, `null`, or string field.
fn nullable_string(params: Params, key: &'static str, value: Update<String>) -> Params {
    match value {
        Update::Unchanged => params,
        Update::Clear => params.value(key, Value::Null),
        Update::Set(value) => params.string(key, value),
    }
}
