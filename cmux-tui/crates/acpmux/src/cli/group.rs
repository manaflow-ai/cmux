//! `acpmux group ls|move|tidy`: the cmux app's sidebar groups, for agents
//! that sort sessions into them (Leo, 2026-11-02: "you didnt do these groups
//! well don't we hav ebetter acpmux commands for you guys yet").
//!
//! - `ls`: every group with its space, members and whether another group in
//!   its space has the same name.
//! - `move SESSION GROUP`: the session's workspace (the one `acpmux new
//!   --group` opened for it) joins GROUP, made only when its space has none.
//! - `tidy`: groups that share a name in one space become one. Each
//!   duplicate's members join the kept group, in their order, then the
//!   emptied duplicate goes. Only duplicates are touched: a group whose name
//!   no other group in its space has stays, empty or not. A dry run unless
//!   `--apply`.
//!
//! Each step is the `cmux` CLI's (`workspace group list|create|add|delete`,
//! `workspace placement list`), so the app's group rules apply unchanged.

use std::collections::BTreeMap;
use std::path::PathBuf;
use std::process::{Command, Stdio};

use anyhow::{Context, Result, anyhow, bail};
use clap::Subcommand;
use serde_json::{Value, json};

use crate::cli::output::print_json;

#[derive(Subcommand, Debug, PartialEq, Eq)]
pub enum GroupCmd {
    /// Every sidebar group: its space, name, members, and DUP when another group
    /// in its space has its name.
    #[command(alias = "list")]
    Ls,
    /// Put SESSION's workspace in group GROUP, made only when its space has
    /// none. The workspace is the one `acpmux new --group` opened for it.
    Move { session: String, group: String },
    /// Make same-named groups in one space one group: members join the first
    /// (a pinned one first), in their order, and each emptied duplicate goes.
    /// Shows the plan; `--apply` does it.
    Tidy {
        #[arg(long)]
        apply: bool,
    },
}

pub async fn run(cmd: GroupCmd, json_out: bool) -> Result<()> {
    match cmd {
        GroupCmd::Ls => {
            let groups = list(&cmux_json(&["workspace", "group", "list"])?, &placements()?);
            if json_out {
                print_json(&json!({"groups": groups}));
            } else {
                for group in &groups {
                    println!(
                        "{:<40} {:>3} {:<10} {}{}",
                        group["name"].as_str().unwrap_or_default(),
                        group["members"].as_array().map_or(0, Vec::len),
                        group["room_id"].as_str().unwrap_or_default(),
                        group["id"].as_str().unwrap_or_default(),
                        if group["duplicate"] == true { "  DUP" } else { "" },
                    );
                }
            }
            Ok(())
        }
        GroupCmd::Move { session, group } => {
            let client = crate::daemon::connect(true).await?;
            let id = crate::cli::run::resolve_id(&client, &session).await?;
            let key = crate::cli::run::launch::workspace_key(&id);
            let workspace = workspace_of(&placements()?, &key).ok_or_else(|| {
                anyhow!(
                    "no sidebar workspace shows session {session} on this Mac; open it in a group \
                     with `acpmux new --group {group}` or `cmux agent open {id} --group {group}`"
                )
            })?;
            let made = cmux_json(&["workspace", "group", "create", "--name", &group, "--reuse"])
                .or_else(|_| find_or_make(&group))?;
            let made = made.get("value").unwrap_or(&made);
            let gid = made["id"].as_str().context("cmux named no group id")?;
            cmux_json(&["workspace", "group", gid, "add", "--workspace", &workspace])?;
            let moved = json!({"session": id, "workspace": workspace, "group": gid, "name": group});
            if json_out {
                print_json(&moved);
            } else {
                println!("{session} -> {group} ({gid})");
            }
            Ok(())
        }
        GroupCmd::Tidy { apply } => {
            let plan = tidy_plan(&cmux_json(&["workspace", "group", "list"])?, &placements()?);
            if apply {
                for merge in &plan {
                    for workspace in &merge.members {
                        cmux_json(&[
                            "workspace",
                            "group",
                            &merge.into,
                            "add",
                            "--workspace",
                            workspace,
                        ])?;
                    }
                    if merge.unmovable == 0 {
                        cmux_json(&["workspace", "group", &merge.from, "delete"])?;
                    }
                }
            }
            if json_out {
                print_json(
                    &json!({"applied": apply, "merges": plan.iter().map(Merge::json).collect::<Vec<_>>()}),
                );
            } else if plan.is_empty() {
                println!("no space has two groups of one name");
            } else {
                for merge in &plan {
                    let left = if merge.unmovable > 0 {
                        format!(", {} kept there (another machine's)", merge.unmovable)
                    } else {
                        String::new()
                    };
                    println!(
                        "{} {:?}: {} -> {} ({} member(s){left})",
                        if apply { "merged" } else { "would merge" },
                        merge.name,
                        merge.from,
                        merge.into,
                        merge.members.len(),
                    );
                }
                if !apply {
                    println!("run `acpmux group tidy --apply` to do it");
                }
            }
            Ok(())
        }
    }
}

/// One duplicate group's merge into the group its space keeps.
#[derive(Debug, PartialEq, Eq)]
pub(crate) struct Merge {
    pub(crate) name: String,
    pub(crate) room: String,
    pub(crate) from: String,
    pub(crate) into: String,
    /// The members `cmux workspace group add` can move (this Mac's), in order.
    pub(crate) members: Vec<String>,
    /// Members of another machine, which stay; the duplicate then stays too.
    pub(crate) unmovable: usize,
}

impl Merge {
    fn json(&self) -> Value {
        json!({"name": self.name, "room_id": self.room, "from": self.from, "into": self.into,
               "members": self.members, "unmovable": self.unmovable})
    }
}

/// The same label: equal once outer spaces are trimmed, case counted.
fn label(name: &str) -> &str {
    name.trim()
}

fn by_index(groups: &Value) -> Vec<&Value> {
    let mut groups: Vec<&Value> = groups.as_array().map(|g| g.iter().collect()).unwrap_or_default();
    groups.sort_by_key(|group| group["index"].as_u64().unwrap_or(u64::MAX));
    groups
}

/// The placements of group `id`, in the personal order.
fn members_of<'a>(placements: &'a [Value], id: &str) -> Vec<&'a Value> {
    let mut members: Vec<&Value> =
        placements.iter().filter(|placement| placement["group_id"] == id).collect();
    members.sort_by_key(|placement| placement["index"].as_u64().unwrap_or(u64::MAX));
    members
}

/// `ls`: each group with its members' workspace ids (null for another
/// machine's) and whether its space has another group of its name.
pub(crate) fn list(groups: &Value, placements: &[Value]) -> Vec<Value> {
    let groups = by_index(groups);
    let mut names: BTreeMap<(String, String), usize> = BTreeMap::new();
    for group in &groups {
        let count = names.entry(key(group)).or_default();
        *count = count.saturating_add(1);
    }
    groups
        .iter()
        .map(|group| {
            let id = group["id"].as_str().unwrap_or_default();
            json!({
                "id": id,
                "name": group["name"],
                "room_id": group["room_id"],
                "pinned": group["pinned"],
                "members": members_of(placements, id).iter()
                    .map(|placement| placement.pointer("/workspace/workspace_id").cloned().unwrap_or(Value::Null)).collect::<Vec<_>>(),
                "duplicate": names.get(&key(group)).is_some_and(|count| *count > 1),
            })
        })
        .collect()
}

fn key(group: &Value) -> (String, String) {
    (
        group["room_id"].as_str().unwrap_or_default().to_owned(),
        label(group["name"].as_str().unwrap_or_default()).to_owned(),
    )
}

/// `tidy`: per space and name, the group kept (a pinned one first, else the
/// first in group order) and a merge for each other group of that name.
pub(crate) fn tidy_plan(groups: &Value, placements: &[Value]) -> Vec<Merge> {
    let mut named: BTreeMap<(String, String), Vec<&Value>> = BTreeMap::new();
    let mut order = Vec::new();
    for group in by_index(groups) {
        let key = key(group);
        if !named.contains_key(&key) {
            order.push(key.clone());
        }
        named.entry(key).or_default().push(group);
    }
    let mut plan = Vec::new();
    for key in order {
        let Some(same) = named.get(&key).filter(|same| same.len() > 1) else {
            continue;
        };
        let Some(kept) = same.iter().find(|group| group["pinned"] == true).or(same.first()) else {
            continue;
        };
        let into = kept["id"].as_str().unwrap_or_default();
        for group in same.iter().filter(|group| group["id"] != into) {
            let from = group["id"].as_str().unwrap_or_default();
            let members = members_of(placements, from);
            let movable: Vec<String> = members
                .iter()
                .filter_map(|placement| {
                    placement.pointer("/workspace/workspace_id").and_then(Value::as_str)
                })
                .map(str::to_owned)
                .collect();
            plan.push(Merge {
                name: key.1.clone(),
                room: key.0.clone(),
                from: from.to_owned(),
                into: into.to_owned(),
                unmovable: members.len().saturating_sub(movable.len()),
                members: movable,
            });
        }
    }
    plan
}

/// The workspace id of this Mac's placement whose workspace key is `key`.
pub(crate) fn workspace_of(placements: &[Value], key: &str) -> Option<String> {
    placements
        .iter()
        .filter(|placement| {
            placement.pointer("/workspace/workspace_ref").and_then(Value::as_str) == Some(key)
        })
        .find_map(|placement| placement.pointer("/workspace/workspace_id").and_then(Value::as_str))
        .map(str::to_owned)
}

/// A daemon without `--reuse`: the space's first group of that name, else a new one.
fn find_or_make(name: &str) -> Result<Value> {
    let groups = cmux_json(&["workspace", "group", "list"])?;
    if let Some(group) = by_index(&groups)
        .into_iter()
        .find(|group| label(group["name"].as_str().unwrap_or_default()) == label(name))
    {
        return Ok(group.clone());
    }
    cmux_json(&["workspace", "group", "create", "--name", name])
}

fn placements() -> Result<Vec<Value>> {
    let value = cmux_json(&["workspace", "placement", "list"])?;
    Ok(value.as_array().cloned().unwrap_or_default())
}

/// Runs `cmux --json ARGS` (the app's bundled CLI when the app started this
/// daemon, else `cmux` on PATH) and parses what it prints.
fn cmux_json(args: &[&str]) -> Result<Value> {
    let cli = std::env::var_os(crate::login_env::BUNDLED_CLI_ENV)
        .map(PathBuf::from)
        .filter(|path| path.is_file())
        .unwrap_or_else(|| PathBuf::from("cmux"));
    let out = Command::new(&cli)
        .arg("--json")
        .args(args)
        .stdin(Stdio::null())
        .output()
        .with_context(|| format!("could not run {} (the cmux app's CLI)", cli.display()))?;
    if !out.status.success() {
        bail!(
            "cmux {} failed ({}): {}",
            args.join(" "),
            out.status,
            String::from_utf8_lossy(&out.stderr).trim()
        );
    }
    serde_json::from_slice(&out.stdout)
        .with_context(|| format!("cmux {} printed no JSON", args.join(" ")))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn placement(group: &str, index: u64, workspace: Option<&str>, key: &str) -> Value {
        json!({"group_id": group, "index": index,
               "workspace": {"workspace_id": workspace, "workspace_ref": key, "session_id": "s"}})
    }

    fn groups() -> Value {
        json!([
            {"id": "grp_l1", "name": "Leads", "room_id": "default", "index": 0, "pinned": false},
            {"id": "grp_t1", "name": "UI think tank", "room_id": "default", "index": 1, "pinned": false},
            {"id": "grp_l2", "name": " Leads", "room_id": "default", "index": 2, "pinned": false},
            {"id": "grp_t2", "name": "UI think tank", "room_id": "default", "index": 3, "pinned": false},
            {"id": "grp_l3", "name": "Leads", "room_id": "side", "index": 4, "pinned": false},
            {"id": "grp_lc", "name": "leads", "room_id": "default", "index": 5, "pinned": false},
            {"id": "grp_solo", "name": "Empty and mine", "room_id": "default", "index": 6, "pinned": false},
        ])
    }

    #[test]
    fn tidy_merges_each_duplicate_into_the_first_of_its_name_in_its_space() {
        let placements = [
            placement("grp_l1", 0, Some("ws_a"), "ka"),
            placement("grp_l2", 2, Some("ws_c"), "kc"),
            placement("grp_l2", 1, Some("ws_b"), "kb"),
        ];
        let plan = tidy_plan(&groups(), &placements);
        assert_eq!(
            plan,
            [
                Merge {
                    name: "Leads".into(),
                    room: "default".into(),
                    from: "grp_l2".into(),
                    into: "grp_l1".into(),
                    members: vec!["ws_b".into(), "ws_c".into()],
                    unmovable: 0,
                },
                Merge {
                    name: "UI think tank".into(),
                    room: "default".into(),
                    from: "grp_t2".into(),
                    into: "grp_t1".into(),
                    members: vec![],
                    unmovable: 0,
                },
            ],
            "another space's Leads, a lowercase leads and a group of its own name stay"
        );
    }

    #[test]
    fn tidy_keeps_a_pinned_group_and_leaves_another_machines_members() {
        let groups = json!([
            {"id": "grp_a", "name": "Leads", "room_id": "default", "index": 0, "pinned": false},
            {"id": "grp_b", "name": "Leads", "room_id": "default", "index": 1, "pinned": true},
        ]);
        let placements =
            [placement("grp_a", 0, Some("ws_a"), "ka"), placement("grp_a", 1, None, "remote")];
        let plan = tidy_plan(&groups, &placements);
        assert_eq!(plan.len(), 1);
        assert_eq!((plan[0].from.as_str(), plan[0].into.as_str()), ("grp_a", "grp_b"));
        assert_eq!(plan[0].members, ["ws_a"]);
        assert_eq!(plan[0].unmovable, 1, "the duplicate keeps another machine's row, so it stays");
    }

    #[test]
    fn ls_marks_duplicates_per_space() {
        let listed = list(&groups(), &[placement("grp_l1", 0, Some("ws_a"), "ka")]);
        let dup: Vec<(&str, bool)> = listed
            .iter()
            .map(|group| (group["id"].as_str().unwrap(), group["duplicate"] == true))
            .collect();
        assert_eq!(
            dup,
            [
                ("grp_l1", true),
                ("grp_t1", true),
                ("grp_l2", true),
                ("grp_t2", true),
                ("grp_l3", false),
                ("grp_lc", false),
                ("grp_solo", false),
            ]
        );
        assert_eq!(listed[0]["members"], json!(["ws_a"]));
    }

    #[test]
    fn move_finds_the_workspace_acpmux_opened_for_the_session() {
        let key = crate::cli::run::launch::workspace_key("peer/abc");
        let placements =
            [placement("grp_x", 0, Some("ws_other"), "k"), placement("", 1, Some("ws_mine"), &key)];
        assert_eq!(workspace_of(&placements, &key).as_deref(), Some("ws_mine"));
        assert_eq!(workspace_of(&placements, "missing"), None);
    }
}
