//! The status of one raw response. A protocol-v12 failure carries an error
//! string and, for expected failures, a machine-readable `error_code` (and
//! sometimes `error_details`), which `Error::Command` keeps; a
//! `cmux.protocol/2` envelope sent through `request_raw` carries a
//! structured error, which keeps its code, message, details and retryability
//! (`Error::Protocol`, or `Error::ConfirmationRequired` with typed details).
//! [`CmuxError::error_code`] reads the code of either form, so a client never
//! parses a message prefix.

use super::{CmuxError, Result};
use serde_json::Value;

pub(crate) fn ensure_success(command: &str, response: &Value) -> Result<()> {
    if response.get("ok") == Some(&Value::Bool(true)) {
        return Ok(());
    }
    let error = response.get("error");
    if let Some(error) = error.filter(|error| error.is_object())
        && let Ok(protocol) = crate::resource::decode_protocol_error(error)
    {
        return Err(protocol);
    }
    let message = match error {
        Some(Value::String(message)) => message.clone(),
        Some(error @ Value::Object(_)) => error.to_string(),
        _ => "unknown command error".to_string(),
    };
    Err(CmuxError::Command {
        command: command.to_string(),
        message,
        id: response.get("id").cloned(),
        error_code: response
            .get("error_code")
            .and_then(Value::as_str)
            .filter(|code| !code.is_empty())
            .map(str::to_string),
        error_details: response
            .get("error_details")
            .filter(|value| !value.is_null())
            .map(|value| Box::new(value.clone())),
    })
}

impl CmuxError {
    /// The daemon's machine-readable code for this failure: a raw command's
    /// `error_code` (for example `frontend_browser_key_closed`,
    /// `invalid_params`, `home_not_closable`), a structured protocol error's
    /// `code` (for example `home.not_closable`), `confirmation.required`, or
    /// the code of the failure a mutation transport error or an ended stream
    /// wraps. `None` when the daemon sent no code or the failure is local.
    pub fn error_code(&self) -> Option<&str> {
        match self {
            Self::Command { error_code, .. } => error_code.as_deref(),
            Self::Protocol { code, .. } => Some(code),
            Self::ConfirmationRequired { .. } => Some("confirmation.required"),
            Self::MutationTransport { source, .. } => source.error_code(),
            Self::StreamEnded { error: Some(error), .. } => error.error_code(),
            _ => None,
        }
    }
}

impl std::error::Error for CmuxError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::MutationTransport { source, .. } => Some(source.as_ref()),
            _ => None,
        }
    }
}
