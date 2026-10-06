//! Home (`workspace-kind-v1`, `conversation-tabs-v1`): `workspace.ensure_home`
//! on a session handle, and the connection's declaration that it reads
//! conversation tabs in their canonical form.

use super::super::*;

/// The capability a connection declares to read a conversation tab as
/// `TabContentKind::Conversation`; without it the server shows that tab as
/// a browser tab on every read path (`session.snapshot`, `session.events`).
pub const CONVERSATION_TABS_CAPABILITY: &str = "conversation-tabs-v1";

/// At most this many capabilities per declaration (catalog
/// `client.metadata.update.capabilities`).
const CAPABILITIES_MAX: usize = 64;
/// Bytes per capability name.
const CAPABILITY_MAX_BYTES: usize = 128;

impl Session {
    /// The session's home workspace (`extra.kind == "home"`) with a fresh
    /// idempotency key. The store creates it on the first call and names the
    /// same workspace on every later one (`replayed` is then true). The
    /// hosting app sends it on every connect when the server advertises
    /// `workspace-kind-v1`.
    pub fn ensure_home(&self) -> Result<Created<Workspace>> {
        self.ensure_home_with(MutationOptions::unique()?)
    }

    pub fn ensure_home_with(&self, mutation: MutationOptions) -> Result<Created<Workspace>> {
        let value = self.client.mutate(ops::WORKSPACE_ENSURE_HOME, self.params(), mutation)?;
        created(value, |path| match path {
            CreatedPath::Workspace { workspace_id } => Ok(self.workspace(workspace_id.clone())),
            _ => Err(Error::UnexpectedEnvelope(
                "workspace.ensure_home must return a workspace path".to_string(),
            )),
        })
    }
}

impl ConnectedClient {
    /// Declares additive capabilities of this connection
    /// (`client.metadata.update {capabilities}`, as raw `set-client-info`),
    /// for example [`CONVERSATION_TABS_CAPABILITY`]. Only the requesting
    /// connection may declare them, so the selector must name this
    /// connection (`Selector::current()`). Declare before `session.snapshot`
    /// and `session.events` so both read the same form.
    pub fn declare_capabilities<I, S>(&self, capabilities: I) -> Result<ClientSnapshot>
    where
        I: IntoIterator<Item = S>,
        S: Into<String>,
    {
        let capabilities: Vec<String> = capabilities.into_iter().map(Into::into).collect();
        if capabilities.is_empty() || capabilities.len() > CAPABILITIES_MAX {
            return Err(Error::InvalidArgument(format!(
                "declare 1 to {CAPABILITIES_MAX} capabilities"
            )));
        }
        if let Some(bad) = capabilities
            .iter()
            .find(|capability| capability.is_empty() || capability.len() > CAPABILITY_MAX_BYTES)
        {
            return Err(Error::InvalidArgument(format!(
                "capability {bad:?} must have 1 to {CAPABILITY_MAX_BYTES} bytes"
            )));
        }
        let params = self.params().value(
            "capabilities",
            Value::Array(capabilities.into_iter().map(Value::String).collect()),
        );
        wire::decode_exact(
            &self.session.client.connection_control(ops::CLIENT_METADATA_UPDATE, params)?,
            "client capability declaration result",
        )
    }
}
