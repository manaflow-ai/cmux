//! Part of `Hub`; see `hub/mod.rs`. Keyset pages of the session list, shared by
//! `_acpmux/sessions` and `_acpmux/watch`.
//!
//! The list is newest first by `updatedAt`, then by `sessionId`. A client that
//! sends `limit` gets that many sessions and a `nextCursor` naming the last one
//! (null when the list is done); `cursor` starts the page after the session it
//! names. A session that moves to the top or leaves meanwhile neither repeats
//! nor skips another one; one that moves to the top before its page is read is
//! not in a later page, and reaches a watching client as `_acpmux/session_changed`.
//! Without `limit` the reply is the whole list, as before.
//!
//! `peer` and `status` narrow the list before it is paged: only the sessions
//! that peer owns (the sidebar's machine group), only those in that status
//! (`closed`: its Older row). A peer's hundreds of closed sessions then come a
//! page at a time instead of the whole multi-megabyte list. Only
//! `_acpmux/sessions` takes them: a watch streams every session's changes, so
//! a filtered first page would promise a scope its events do not keep
//! (`refuse_watch_filters`).

use super::*;

/// Sorts session summaries newest first, ties by `sessionId` ascending. The
/// summaries are snapshots, so the order is total while sorting.
pub(crate) fn sort_session_summaries(list: &mut [Value]) {
    list.sort_by(|a, b| {
        updated_ms(b).cmp(&updated_ms(a)).then_with(|| session_id(a).cmp(session_id(b)))
    });
}

/// The session list reply for `params`: `{sessions}` without `limit`,
/// `{sessions, nextCursor}` with it.
pub(crate) fn session_list_reply(sorted: Vec<Value>, params: &Value) -> Result<Value, RpcError> {
    let limit = match params.get("limit") {
        None | Some(Value::Null) => None,
        Some(v) => Some(
            v.as_u64()
                .filter(|&n| n > 0)
                .ok_or_else(|| RpcError::invalid_params("limit must be a positive integer"))?,
        ),
    };
    let cursor =
        match params.get("cursor") {
            None | Some(Value::Null) => None,
            Some(Value::String(text)) => Some(SessionCursor::parse(text).ok_or_else(|| {
                RpcError::invalid_params(format!("cursor {text:?} is not a cursor"))
            })?),
            Some(_) => return Err(RpcError::invalid_params("cursor must be a string")),
        };
    let peer = text_filter(params, "peer")?;
    let status = text_filter(params, "status")?;
    let sorted: Vec<Value> = if peer.is_none() && status.is_none() {
        sorted
    } else {
        sorted
            .into_iter()
            .filter(|s| peer.is_none_or(|p| s.get("peer").and_then(Value::as_str) == Some(p)))
            .filter(|s| status.is_none_or(|st| s.get("status").and_then(Value::as_str) == Some(st)))
            .collect()
    };
    let start = cursor.map_or(0, |c| c.start(&sorted));
    let mut sessions: Vec<Value> = sorted.into_iter().skip(start).collect();
    let Some(limit) = limit else {
        return Ok(json!({"sessions": sessions}));
    };
    let limit = usize::try_from(limit).unwrap_or(usize::MAX);
    let next = if sessions.len() > limit {
        sessions.truncate(limit);
        sessions.last().map(|last| SessionCursor::after(last).to_text())
    } else {
        None
    };
    Ok(json!({"sessions": sessions, "nextCursor": next}))
}

/// A string filter param: absent, null or empty is no filter (the schema allows all three);
/// another type is refused.
fn text_filter<'a>(params: &'a Value, name: &str) -> Result<Option<&'a str>, RpcError> {
    match params.get(name) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(text)) => Ok((!text.is_empty()).then_some(text.as_str())),
        Some(_) => Err(RpcError::invalid_params(format!("{name} must be a string"))),
    }
}

/// `_acpmux/watch` refuses `peer` and `status`: its events cover every session.
pub(crate) fn refuse_watch_filters(params: &Value) -> Result<(), RpcError> {
    for name in ["peer", "status"] {
        if text_filter(params, name)?.is_some() {
            return Err(RpcError::invalid_params(format!(
                "{name} filters _acpmux/sessions only: a watch streams every session"
            )));
        }
    }
    Ok(())
}

/// After the session updated at `updated_ms` whose id hashes to `key`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct SessionCursor {
    updated_ms: u64,
    key: u64,
}

impl SessionCursor {
    fn after(session: &Value) -> Self {
        Self { updated_ms: stamp(session), key: id_hash(session_id(session)) }
    }

    /// `k<stamp hex>.<id hash hex>`: at most 30 characters (the app passes at most 32).
    fn to_text(self) -> String {
        format!("k{:x}.{:016x}", self.updated_ms, self.key)
    }

    fn parse(text: &str) -> Option<Self> {
        let (updated, key) = text.strip_prefix('k')?.split_once('.')?;
        if updated.is_empty() || updated.len() > 12 || key.is_empty() || key.len() > 16 {
            return None;
        }
        Some(Self {
            updated_ms: u64::from_str_radix(updated, 16).ok()?,
            key: u64::from_str_radix(key, 16).ok()?,
        })
    }

    /// Where the page starts in `sorted`. The named session gone or moved, the
    /// page starts at the first session no newer than it was: one updated in
    /// that same millisecond may repeat, none is skipped.
    fn start(self, sorted: &[Value]) -> usize {
        sorted
            .iter()
            .position(|s| stamp(s) == self.updated_ms && id_hash(session_id(s)) == self.key)
            .map(|at| at + 1)
            .unwrap_or_else(|| {
                sorted.iter().position(|s| stamp(s) <= self.updated_ms).unwrap_or(sorted.len())
            })
    }
}

fn updated_ms(session: &Value) -> u64 {
    session.get("updatedAt").and_then(Value::as_u64).unwrap_or(0)
}

/// The cursor's timestamp: `updatedAt` clamped to 12 hex digits (year 10889), the same in the
/// cursor and in both comparisons, so a huge stamp still matches its own cursor and the cursor
/// stays at most 30 characters.
fn stamp(session: &Value) -> u64 {
    updated_ms(session).min(MAX_STAMP)
}

const MAX_STAMP: u64 = 0xffff_ffff_ffff;

fn session_id(session: &Value) -> &str {
    session.get("sessionId").and_then(Value::as_str).unwrap_or("")
}

/// FNV-1a of the session id: the same in every daemon run.
fn id_hash(id: &str) -> u64 {
    id.bytes().fold(0xcbf2_9ce4_8422_2325, |hash, byte| {
        (hash ^ u64::from(byte)).wrapping_mul(0x0100_0000_01b3)
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn list() -> Vec<Value> {
        let mut list = vec![
            json!({"sessionId": "a", "updatedAt": 5, "peer": "huge-blue", "status": "closed"}),
            json!({"sessionId": "b", "updatedAt": 4, "peer": "huge-blue", "status": "idle"}),
            json!({"sessionId": "c", "updatedAt": 3, "peer": "huge-blue", "status": "closed"}),
            json!({"sessionId": "d", "updatedAt": 2, "peer": "cmux16", "status": "closed"}),
            json!({"sessionId": "e", "updatedAt": 1, "status": "closed"}),
        ];
        sort_session_summaries(&mut list);
        list
    }

    fn ids(reply: &Value) -> Vec<&str> {
        reply["sessions"].as_array().unwrap().iter().map(session_id).collect()
    }

    #[test]
    fn peer_and_status_narrow_the_list_before_it_is_paged() {
        let reply = session_list_reply(
            list(),
            &json!({"peer": "huge-blue", "status": "closed", "limit": 1}),
        )
        .unwrap();
        assert_eq!(ids(&reply), ["a"]);
        let next = reply["nextCursor"].as_str().unwrap().to_owned();
        let reply = session_list_reply(
            list(),
            &json!({"peer": "huge-blue", "status": "closed", "limit": 1, "cursor": next}),
        )
        .unwrap();
        assert_eq!(ids(&reply), ["c"]);
        assert_eq!(reply["nextCursor"], Value::Null);
    }

    #[test]
    fn each_filter_alone_and_none_keeps_the_old_reply() {
        assert_eq!(ids(&session_list_reply(list(), &json!({"peer": "cmux16"})).unwrap()), ["d"]);
        assert_eq!(
            ids(&session_list_reply(list(), &json!({"status": "closed"})).unwrap()),
            ["a", "c", "d", "e"]
        );
        assert_eq!(
            ids(&session_list_reply(list(), &json!({"peer": null})).unwrap()),
            ["a", "b", "c", "d", "e"]
        );
    }

    #[test]
    fn an_empty_filter_is_none_and_a_non_string_one_is_refused() {
        assert_eq!(ids(&session_list_reply(list(), &json!({"peer": ""})).unwrap()).len(), 5);
        assert!(session_list_reply(list(), &json!({"status": 3})).is_err());
    }

    #[test]
    fn a_watch_refuses_filters_its_events_would_not_keep() {
        assert!(refuse_watch_filters(&json!({"peer": "huge-blue"})).is_err());
        assert!(refuse_watch_filters(&json!({"status": "closed", "limit": 5})).is_err());
        assert!(refuse_watch_filters(&json!({"limit": 5, "peer": null, "status": ""})).is_ok());
    }
}
