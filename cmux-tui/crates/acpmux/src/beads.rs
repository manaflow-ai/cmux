//! Beads on a session: the team's `bd` tracker ids (`cx-cus7j.230`) a session works on, kept as
//! the session's tags `bead:<id>` (the value is when it was linked, unix ms). A tag rides the
//! session everywhere a tag does: its summary, a peer's mirrored list, a restart. `acpmux bead
//! link|unlink` sets them, `acpmux task new --bead` sets them when it gives the work, and `acpmux resolve <bead id>` (`hub/locate.rs`) finds the sessions that carry
//! one, here or on a peer. The tracker itself (who a bead is assigned to) stays the tracker's.

use serde_json::Value;

/// The tag key prefix of a linked bead.
pub const TAG_PREFIX: &str = "bead:";

/// A tracker id: a prefix (letters, digits, `-`), `-`, a hash, then any child steps of letters
/// and digits (`cx-cus7j.230`, `cx-0op.M1a`), at most 64 characters.
pub fn is_bead_id(s: &str) -> bool {
    let mut steps = s.split('.');
    let head = steps.next().unwrap_or_default();
    let Some((prefix, hash)) = head.rsplit_once('-') else { return false };
    s.len() <= 64
        && prefix.starts_with(|c: char| c.is_ascii_alphabetic())
        && prefix.chars().all(|c| c.is_ascii_alphanumeric() || c == '-')
        && !hash.is_empty()
        && hash.chars().all(|c| c.is_ascii_alphanumeric())
        && steps.all(|n| !n.is_empty() && n.chars().all(|c| c.is_ascii_alphanumeric()))
}

/// `bead:<id>`, the tag that links bead `id`.
pub fn tag_key(id: &str) -> String {
    format!("{TAG_PREFIX}{id}")
}

/// The bead ids a session's `tags` (its summary's) link, in id order.
pub fn of_tags(tags: &Value) -> Vec<String> {
    let mut ids: Vec<String> = tags
        .as_object()
        .into_iter()
        .flatten()
        .filter_map(|(k, _)| k.strip_prefix(TAG_PREFIX))
        .filter(|id| is_bead_id(id))
        .map(str::to_owned)
        .collect();
    ids.sort();
    ids
}

/// Each of `ids` checked as a bead id, for a command line.
pub fn checked(ids: &[String]) -> anyhow::Result<()> {
    match ids.iter().find(|id| !is_bead_id(id)) {
        Some(bad) => anyhow::bail!("{bad:?} is not a bead id (like cx-cus7j or cx-cus7j.230)"),
        None => Ok(()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn tracker_ids_are_bead_ids() {
        for id in ["cx-cus7j", "cx-cus7j.230", "cx-ncc.112.129", "cx-0op.M1a", "agent-tasks-a1"] {
            assert!(is_bead_id(id), "{id}");
        }
        for not in
            ["review", "cx-", "-abc", "cx-abc.", "cx-abc..1", "cx-a_b", "cx abc", "1x-abc", "a/b-c"]
        {
            assert!(!is_bead_id(not), "{not}");
        }
    }

    #[test]
    fn a_sessions_beads_are_its_bead_tags() {
        let tags = json!({"bead:cx-b.2": "1", "archived": "2", "bead:cx-a": "3", "bead:nope": "4"});
        assert_eq!(of_tags(&tags), ["cx-a", "cx-b.2"]);
        assert!(of_tags(&Value::Null).is_empty());
    }
}
