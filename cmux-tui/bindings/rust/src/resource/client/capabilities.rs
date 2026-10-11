//! Capabilities on every connection: `Config::capabilities` and what
//! `ConnectedClient::declare_capabilities` declared go out as
//! `client.metadata.update {capabilities}` first on each connection the
//! client opens (the control connection, a reconnect of it, each stream),
//! because the server keeps capabilities per connection.

use super::super::id::{ConnectedClientId, MachineId, SessionId};
use super::super::wire::{Params, field};
use super::super::{Selector, ops};
use super::{
    CallBudget, Client, connect_with_budget, receive_response_with_budget, request_envelope,
};
use crate::codec::JsonLineConnection;
use crate::{Error, Result};
use serde_json::Value;

/// At most this many capabilities per declaration (catalog
/// `client.metadata.update.capabilities`).
pub(crate) const CAPABILITIES_MAX: usize = 64;
/// Bytes per capability name.
pub(crate) const CAPABILITY_MAX_BYTES: usize = 128;

/// At most [`CAPABILITIES_MAX`] names of 1 to [`CAPABILITY_MAX_BYTES`]
/// bytes; `declare_capabilities` also needs at least one.
pub(crate) fn validate_capabilities(capabilities: &[String]) -> Result<()> {
    if capabilities.len() > CAPABILITIES_MAX {
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
    Ok(())
}

/// `client.metadata.update` params that declare `capabilities` for the
/// requesting connection.
pub(crate) fn capability_params(capabilities: &[String]) -> Params {
    Params::new()
        .selector(field::MACHINE, &Selector::<MachineId>::current())
        .selector(field::SESSION, &Selector::<SessionId>::current())
        .selector(field::CLIENT, &Selector::<ConnectedClientId>::current())
        .value(
            "capabilities",
            Value::Array(capabilities.iter().cloned().map(Value::String).collect()),
        )
}

impl super::Config {
    /// Declares `capabilities` on every connection the client opens.
    pub fn with_capabilities<I, S>(mut self, capabilities: I) -> Self
    where
        I: IntoIterator<Item = S>,
        S: Into<String>,
    {
        self.capabilities = capabilities.into_iter().map(Into::into).collect();
        self
    }
}

impl Client {
    /// The client after its capabilities were declared on the control
    /// connection (the connection is closed when that fails).
    pub(super) fn declared_on_control(self) -> Result<Self> {
        if self.capabilities().is_empty() {
            return Ok(self);
        }
        let budget = CallBudget::new(Default::default(), self.shared.config.timeout)?;
        let mut control = self
            .shared
            .control
            .lock()
            .map_err(|_| Error::Connection("client connection lock poisoned".to_string()))?;
        let connection = control.as_mut().ok_or(Error::Closed)?;
        if let Err(error) = self.declare_on(connection, ops::CLIENT_METADATA_UPDATE, &budget) {
            if let Some(connection) = control.take() {
                connection.close();
            }
            return Err(error);
        }
        drop(control);
        Ok(self)
    }

    /// A new connection for `operation`, with the client's capabilities
    /// declared on it before anything else is sent.
    pub(super) fn open_connection(
        &self,
        operation: &str,
        budget: &CallBudget,
    ) -> Result<JsonLineConnection> {
        let mut connection = connect_with_budget(
            &self.shared.config,
            operation,
            budget,
            self.shared.allow_legacy_fallback,
        )?;
        if let Err(error) = self.declare_on(&mut connection, operation, budget) {
            connection.close();
            return Err(error);
        }
        Ok(connection)
    }

    /// Declares the client's capabilities on `connection` (nothing when it
    /// has none) and waits for the answer.
    pub(super) fn declare_on(
        &self,
        connection: &mut JsonLineConnection,
        operation: &str,
        budget: &CallBudget,
    ) -> Result<()> {
        let capabilities = self.capabilities();
        if capabilities.is_empty() {
            return Ok(());
        }
        let id = self.next_request_id();
        let params = capability_params(&capabilities).into_value();
        let envelope = request_envelope(&id, ops::CLIENT_METADATA_UPDATE, params, None);
        let send_timeout = budget.remaining(operation)?;
        connection.with_write_timeout(send_timeout, |connection| {
            connection.send_with_limit(&envelope, self.shared.config.max_request_bytes)
        })?;
        receive_response_with_budget(connection, &id, operation, budget).map(|_| ())
    }

    /// The capabilities every new connection of this client declares.
    pub fn capabilities(&self) -> Vec<String> {
        self.shared.capabilities.lock().map(|c| c.clone()).unwrap_or_default()
    }

    /// Adds `capabilities` (declared on the control connection) to what
    /// later connections declare.
    pub(crate) fn remember_capabilities(&self, capabilities: &[String]) {
        if let Ok(mut known) = self.shared.capabilities.lock() {
            for capability in capabilities {
                if !known.contains(capability) {
                    known.push(capability.clone());
                }
            }
        }
    }
}
