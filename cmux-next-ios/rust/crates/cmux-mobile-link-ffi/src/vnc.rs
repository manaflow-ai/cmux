//! The VNC client's rules for Packages/Shared/CmuxVNC on the phone: the
//! `vnc_*` ops of `cmux_vnc::json` (addresses, keysyms, the security choice,
//! the version banner, the authentication responses), the same ops the Mac
//! answers over cmux-layout-reducer-ffi's C ABI.

/// Why [`vnc_json`] gave no answer.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error, uniffi::Error)]
pub enum VncJsonError {
    #[error("unknown vnc op {operation}")]
    UnknownOperation { operation: String },
    #[error("invalid vnc request: {detail}")]
    Invalid { detail: String },
}

/// Answers one `vnc_*` op: `request` and the answer are JSON.
#[uniffi::export]
pub fn vnc_json(operation: String, request: String) -> Result<String, VncJsonError> {
    use cmux_vnc::json::{JsonError, respond};
    match respond(&operation, request.as_bytes()) {
        Ok(answer) => Ok(answer.to_string()),
        Err(JsonError::UnknownOperation(operation)) => Err(VncJsonError::UnknownOperation { operation }),
        Err(JsonError::Invalid(detail)) => Err(VncJsonError::Invalid { detail }),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn answers_and_refuses_as_the_mac_does() {
        assert_eq!(vnc_json("vnc_keysym".into(), r#"{"hidUsage":4}"#.into()), Ok(r#"{"keysym":97}"#.into()));
        assert!(matches!(
            vnc_json("vnc_nope".into(), "{}".into()),
            Err(VncJsonError::UnknownOperation { .. })
        ));
        assert!(matches!(vnc_json("vnc_keysym".into(), "{".into()), Err(VncJsonError::Invalid { .. })));
    }
}
