use super::*;

/// The rotation `websocket.tokenRotated` records (see `rotate_saved_token_once`).
pub(crate) const TOKEN_ROTATION: u32 = 1;

/// Builds before this one sent the saved WebSocket token to remote-origin
/// connections (`_acpmux/status` `webUrl`), so a token saved by one may be
/// known elsewhere: replace it once, at the first start of this build, and
/// mark it so it never rotates again. Every reader takes the token fresh
/// (the app's host and `acpmux web` from `_acpmux/status` over the unix
/// socket, ssh peers from the remote config at each connect); a `--token`
/// flag still overrides the listener's token. Returns whether it rotated.
pub(super) fn rotate_saved_token_once(config: &mut crate::config::Config) -> bool {
    let Some(w) = config.websocket.as_mut() else { return false };
    if w.token_rotated >= TOKEN_ROTATION || w.token.as_deref().is_none_or(|t| t.trim().is_empty()) {
        return false;
    }
    let fresh = match random_token() {
        Ok(token) => token,
        Err(e) => {
            // Keep the saved token and try again at the next start.
            tracing::warn!("could not rotate the saved WebSocket token: {e}");
            return false;
        }
    };
    let old = w.token.replace(fresh);
    w.token_rotated = TOKEN_ROTATION;
    match config.save() {
        Ok(()) => {
            tracing::info!(
                "the saved WebSocket token was rotated once; run `acpmux web` for the new link"
            );
            true
        }
        Err(e) => {
            // Never run on a token the file does not hold (ssh peers read
            // the file): keep the old one and rotate at the next start.
            tracing::warn!("could not save the rotated WebSocket token; rotating next start: {e}");
            if let Some(w) = config.websocket.as_mut() {
                w.token = old;
                w.token_rotated = 0;
            }
            false
        }
    }
}

pub(super) fn random_token() -> Result<String> {
    let mut bytes = [0u8; 24];
    getrandom::fill(&mut bytes).map_err(|e| anyhow!("the OS random generator: {e}"))?;
    Ok(bytes.iter().map(|b| format!("{b:02x}")).collect())
}
