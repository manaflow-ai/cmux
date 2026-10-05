//! The status of one raw response. A protocol-v12 failure carries an error
//! string; a `cmux.protocol/2` envelope sent through `request_raw` carries a
//! structured error, which keeps its code, message, details and retryability
//! (`Error::Protocol`, or `Error::ConfirmationRequired` with typed details).

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
    })
}
