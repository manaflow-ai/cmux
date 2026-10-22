//! `acpmux ls --tree`: the session list as the forest its lineage draws (`hub/lineage.rs`).
//! Each session sits under the one whose agent started it (its `parent`), depth first, in the
//! list's own order. A session whose parent is not in the list (purged, filtered out by
//! `--status`, or a peer's on an older acpmux) is a root.

use serde_json::Value;
use std::collections::HashMap;

/// The key a summary is found by: its id on its daemon (`peer`, none for this one).
fn key(peer: &Value, id: &str) -> String {
    format!("{}\u{0}{id}", peer.as_str().unwrap_or(""))
}

/// The roots of the forest and each session's children, as indexes into `sessions`.
fn forest(sessions: &[Value]) -> (Vec<usize>, Vec<Vec<usize>>) {
    let at: HashMap<String, usize> = sessions
        .iter()
        .enumerate()
        .filter_map(|(i, s)| Some((key(&s["peer"], s["sessionId"].as_str()?), i)))
        .collect();
    let mut roots = Vec::new();
    let mut children = vec![Vec::new(); sessions.len()];
    for (i, s) in sessions.iter().enumerate() {
        let parent = s["parent"].as_str().and_then(|p| at.get(&key(&s["peer"], p)).copied());
        match parent {
            Some(p) if p != i => children[p].push(i),
            _ => roots.push(i),
        }
    }
    (roots, children)
}

/// The sessions in tree order, each with its depth in the drawn tree (0 for a root).
pub fn ordered(sessions: &[Value]) -> Vec<(usize, &Value)> {
    let (roots, children) = forest(sessions);
    let mut seen = vec![false; sessions.len()];
    let mut out = Vec::with_capacity(sessions.len());
    // A parent loop (no root above it) is drawn from its first member, so every session shows.
    let starts: Vec<usize> = roots.into_iter().chain(0..sessions.len()).collect();
    for start in starts {
        let mut stack = vec![(start, 0usize)];
        while let Some((i, depth)) = stack.pop() {
            if std::mem::replace(&mut seen[i], true) {
                continue;
            }
            out.push((depth, &sessions[i]));
            stack.extend(children[i].iter().rev().map(|&c| (c, depth + 1)));
        }
    }
    out
}

/// The forest as nested summaries: each with its children under `lineageChildren`.
pub fn nested(sessions: &[Value]) -> Vec<Value> {
    let ordered = ordered(sessions);
    // Built bottom up: a session's children come right after it, one level deeper.
    let mut levels: Vec<Vec<Value>> = vec![Vec::new()];
    for (depth, s) in ordered.into_iter().rev() {
        while levels.len() <= depth + 1 {
            levels.push(Vec::new());
        }
        let mut node = s.clone();
        let mut kids = std::mem::take(&mut levels[depth + 1]);
        kids.reverse();
        node["lineageChildren"] = Value::Array(kids);
        levels[depth].push(node);
    }
    let mut roots = std::mem::take(&mut levels[0]);
    roots.reverse();
    roots
}

/// A session's name drawn at `depth` in the tree, cut to `width` characters.
pub fn drawn_name(depth: usize, name: &str, width: usize) -> String {
    let prefix = match depth {
        0 => String::new(),
        d => format!("{}└ ", "  ".repeat(d - 1)),
    };
    let room = width.saturating_sub(prefix.chars().count()).max(1);
    format!("{prefix}{}", crate::cli::output::short(name, room))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn s(id: &str, parent: Option<&str>) -> Value {
        json!({"sessionId": id, "name": id, "parent": parent})
    }

    #[test]
    fn children_follow_their_parent_depth_first_in_list_order() {
        // The daemon lists newest first: children may come before their parent.
        let list = [
            s("grandkid", Some("kid-a")),
            s("kid-b", Some("coord")),
            s("person", None),
            s("kid-a", Some("coord")),
            s("coord", None),
            s("orphan", Some("purged")),
        ];
        let order: Vec<(usize, &str)> =
            ordered(&list).into_iter().map(|(d, v)| (d, v["sessionId"].as_str().unwrap())).collect();
        assert_eq!(
            order,
            [
                (0, "person"),
                (0, "coord"),
                (1, "kid-b"),
                (1, "kid-a"),
                (2, "grandkid"),
                (0, "orphan"),
            ]
        );
    }

    #[test]
    fn json_tree_nests_children_under_lineage_children() {
        let list = [s("kid", Some("root")), s("root", None), s("grandkid", Some("kid"))];
        let tree = nested(&list);
        assert_eq!(tree.len(), 1, "{tree:?}");
        assert_eq!(tree[0]["sessionId"], "root");
        let kids = tree[0]["lineageChildren"].as_array().unwrap();
        assert_eq!(kids.len(), 1);
        assert_eq!(kids[0]["sessionId"], "kid");
        let grandkids = kids[0]["lineageChildren"].as_array().unwrap();
        assert_eq!(grandkids[0]["sessionId"], "grandkid");
        assert_eq!(grandkids[0]["lineageChildren"], json!([]));
    }

    #[test]
    fn a_peer_session_finds_its_parent_on_its_own_peer_and_a_loop_still_shows() {
        let mut remote_kid = s("kid", Some("root"));
        remote_kid["peer"] = json!("box");
        let mut remote_root = s("root", None);
        remote_root["peer"] = json!("box");
        let list = [remote_kid, s("root", None), remote_root, s("a", Some("b")), s("b", Some("a"))];
        let order: Vec<usize> = ordered(&list).into_iter().map(|(d, _)| d).collect();
        assert_eq!(order.len(), 5, "every session is drawn once");
        let nested = nested(&list);
        let remote = nested.iter().find(|n| n["peer"] == "box").unwrap();
        assert_eq!(remote["lineageChildren"][0]["sessionId"], "kid");
    }

    #[test]
    fn a_name_is_indented_by_its_depth() {
        assert_eq!(drawn_name(0, "coord", 24), "coord");
        assert_eq!(drawn_name(1, "lane", 24), "└ lane");
        assert_eq!(drawn_name(2, "review", 24), "  └ review");
        assert_eq!(drawn_name(2, "a-very-long-session-name", 12), "  └ a-very-…");
    }
}
