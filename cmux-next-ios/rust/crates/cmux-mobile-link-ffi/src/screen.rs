//! The screen stream's rules (`cmux-rd-screen`) for the shared Swift packages
//! (Packages/Shared/CmuxVNCWebRTC) in cmux-next-ios. `screen_json(op,
//! request)` answers the same `screen_*` ops the Mac reaches over
//! cmux-layout-reducer-ffi's C ABI: both call `cmux_rd_screen::json::respond`,
//! so a rule cannot answer one way on the Mac and another on the phone.
//!
//! JSON, not records: the shared packages take the rules as one injected
//! closure, filled from CCmuxAppFFI on the Mac and from this library on the
//! phone, and string in, string out is the shape both links have.

use cmux_rd_screen::json::{self, JsonError};

/// Why `screen_json` gave no answer. A refusal the rules make (a bad ticket)
/// is an answer (`{"error": ...}`), not this.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error, uniffi::Error)]
pub enum ScreenJsonError {
    /// No `screen_*` op of that name.
    #[error("unknown screen op {operation:?}")]
    UnknownOperation { operation: String },
    /// The request is not the op's JSON.
    #[error("invalid screen request: {detail}")]
    Invalid { detail: String },
}

impl From<JsonError> for ScreenJsonError {
    fn from(error: JsonError) -> Self {
        match error {
            JsonError::UnknownOperation(operation) => Self::UnknownOperation { operation },
            JsonError::Invalid(detail) => Self::Invalid { detail },
        }
    }
}

/// Answers one `screen_*` op: `request` and the answer are the op's JSON.
#[uniffi::export]
pub fn screen_json(operation: String, request: String) -> Result<String, ScreenJsonError> {
    Ok(json::respond(&operation, request.as_bytes())?.to_string())
}

#[cfg(test)]
mod tests {
    use serde_json::{Value, json};

    use super::*;

    #[test]
    fn answers_as_the_mac_and_names_its_errors() {
        let request = json!({"longEdge": 1179, "displayLongEdge": 3456, "now": 0.0});
        let phone: Value =
            serde_json::from_str(&screen_json("screen_demand_report".into(), request.to_string()).unwrap())
                .unwrap();
        let mac = json::respond("screen_demand_report", request.to_string().as_bytes()).unwrap();
        assert_eq!(phone, mac);
        assert_eq!(
            screen_json("screen_nope".into(), "{}".into()),
            Err(ScreenJsonError::UnknownOperation { operation: "screen_nope".into() })
        );
        assert!(matches!(
            screen_json("screen_demand_report".into(), "[".into()),
            Err(ScreenJsonError::Invalid { .. })
        ));
    }
}
