//! Hosts an adoption could not resolve (#23322 a3 fence, review of the #26241 transport fix): a
//! record this build can not read, records that could not be listed, or a host whose end at
//! adoption failed. Such a host may still hold a fenced line the previous daemon handed it, and
//! nothing proves otherwise, so a fence held for it (`Fence::unresolved`) is cut only once
//! [`end_unresolved`] proves that no host of its session (any session's, for `None`) lives.

use super::*;

/// Ends every host of `session` (of every session for `None`) that a record in the hosts
/// directory names, by its start nonce, and says whether none of them is left: every record
/// was read, each live one ended, and no live lock of such a session stays (one whose record
/// gives no nonce can not be ended, so it is never proven gone while it lives).
pub fn end_unresolved(session: Option<&str>) -> bool {
    let dir = hosts_dir();
    let Ok((good, bad)) = load_records(&dir) else { return false };
    let wanted = |sid: &str| session.is_none_or(|s| s == sid);
    let mut ended = true;
    for (_, r) in good.iter().filter(|(_, r)| wanted(&r.session_id)) {
        for d in live_lock_dirs(r) {
            if live_lock_exists(&d, &r.session_id, &r.start_nonce) {
                let nonce = Some(r.start_nonce.as_str());
                ended &= terminate_unadoptable(&d, &r.session_id, nonce, Some(r.host_pid))
                    .unwrap_or(false);
            }
        }
    }
    for b in bad.iter().filter(|b| wanted(&b.session_id)) {
        if let Some(nonce) = b.start_nonce.as_deref() {
            ended &= terminate_unadoptable(&dir, &b.session_id, Some(nonce), b.host_pid)
                .unwrap_or(false);
        }
    }
    ended && no_live_lock(&dir, session)
}

/// Whether no live lock in `dir` belongs to `session` (any session's, for `None`): each is
/// `<session>.<start nonce>.live`, and one that can not be probed counts as live.
fn no_live_lock(dir: &Path, session: Option<&str>) -> bool {
    let entries = match std::fs::read_dir(dir) {
        Ok(entries) => entries,
        Err(e) => return e.kind() == std::io::ErrorKind::NotFound,
    };
    for entry in entries {
        // An entry that can not be read may be a live lock: fail closed.
        let Ok(entry) = entry else { return false };
        let name = entry.file_name().to_string_lossy().into_owned();
        let Some((sid, nonce)) = name.strip_suffix(".live").and_then(|n| n.rsplit_once('.')) else {
            continue;
        };
        if session.is_none_or(|s| s == sid) && liveness(dir, sid, nonce) != Liveness::Dead {
            return false;
        }
    }
    true
}
