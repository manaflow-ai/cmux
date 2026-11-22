//! chief.engine.get's `offered.harnesses`: the engines the Chief's picker
//! lists (Leo #89 item 3: Claude Code via sr2, Codex, OpenCode, the other
//! acpmux harnesses, UniiChat), each with what it supports and, when it
//! cannot run a turn, why. The Chief harness (the person's chat with a
//! Chief) is never listed. Read from acpmux's `_acpmux/harnesses` at each
//! answer, so a harness installed or signed in since is seen at once.
//!
//! Row: `{"id", "displayName", "family", "chiefFamily", "kind",
//! "capabilities": {"efforts", "speeds", "resume"?, "permissionModes"?,
//! "fast"?}, "unavailable": bool, "unavailableReason"?, "description"?,
//! "icon"?, "login"?}`, by id. `family` is acpmux's (opencode, unii, ...);
//! `chiefFamily` is the layout the Chief gives it (claude, codex, other),
//! which decides the speeds. A terminal-only harness never runs a Chief
//! turn and is not listed.
//!
//! A row never offers what `chief.engine.set` would refuse, since the picker
//! acts on this list: a harness the brain did not read at its start is marked
//! unavailable ("restart the Chief"), because the set checks the start-up
//! families; and a declared effort the set does not take is left out.

use std::collections::{BTreeMap, BTreeSet};

use serde_json::{Map, Value, json};

use crate::acpmux::Family;

/// The rows for an `_acpmux/harnesses` answer.
///
/// - `started_with`: the families the brain read at its start
///   (``Settings::families``), which is what a set checks a harness against;
///   empty means the set checks no harness.
/// - `set_family`: the family a set would check a harness's speed against
///   (``Brain::family_of``), which is the start-up family, not the live one.
pub(super) fn offered_harnesses(
    answer: &Value,
    started_with: &BTreeMap<String, Family>,
    set_family: impl Fn(&str) -> Family,
) -> Vec<Value> {
    let Some(profiles) = answer.get("harnesses").and_then(Value::as_object) else {
        return Vec::new();
    };
    // The curated catalog's name of each profile (`Claude Code` for both
    // `claude` and `claude-sr`).
    let mut catalog_names: BTreeMap<&str, &str> = BTreeMap::new();
    for h in answer
        .pointer("/catalog/harnesses")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
    {
        // An empty catalog name is no name: the row falls back to its id,
        // never to a blank picker label.
        let Some(name) = h
            .get("name")
            .and_then(Value::as_str)
            .filter(|n| !n.is_empty())
        else {
            continue;
        };
        for p in h
            .get("profiles")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
        {
            if let Some(p) = p.as_str() {
                catalog_names.insert(p, name);
            }
        }
    }
    let mut rows: Vec<Value> = profiles
        .iter()
        .filter(|(_, p)| p.get("kind").and_then(Value::as_str) != Some("terminal"))
        // The person's chat with a Chief is never an engine a Chief runs on (harness_gate).
        .filter(|(id, _)| !crate::harness_gate::is_chief_harness(answer, id))
        .map(|(id, p)| {
            row(
                answer,
                id,
                p,
                catalog_names.get(id.as_str()).copied(),
                started_with,
                &set_family,
            )
        })
        .collect();
    rows.sort_by(|a, b| a["id"].as_str().cmp(&b["id"].as_str()));
    disambiguate(&mut rows);
    rows
}

/// Two profiles under one name keep apart by their ids, and no two rows leave
/// the picker with the same name.
///
/// A row wants `name`, or `name (id)` when another row wants the same `name`.
/// What it wants can be taken anyway, by a profile acpmux literally calls
/// `Claude Code (claude)` or `claude`, so the wanted name is then given up for
/// the id, and that for `id (2)`, `id (3)`... Rows are walked in id order
/// (``offered_harnesses`` sorted them), so the result does not depend on the
/// order acpmux listed them in.
fn disambiguate(rows: &mut [Value]) {
    let name_of = |r: &Value| r["displayName"].as_str().unwrap_or_default().to_owned();
    let id_of = |r: &Value| r["id"].as_str().unwrap_or_default().to_owned();
    let mut shared: BTreeMap<String, usize> = BTreeMap::new();
    for r in rows.iter() {
        *shared.entry(name_of(r)).or_default() += 1;
    }
    let mut taken: BTreeSet<String> = BTreeSet::new();
    for r in rows.iter_mut() {
        let (name, id) = (name_of(r), id_of(r));
        let wanted = if shared.get(&name).copied().unwrap_or(0) > 1 && name != id {
            format!("{name} ({id})")
        } else {
            name
        };
        let mut pick = wanted;
        if taken.contains(&pick) {
            pick = id.clone();
            for n in 2.. {
                if !taken.contains(&pick) {
                    break;
                }
                pick = format!("{id} ({n})");
            }
        }
        r["displayName"] = json!(pick);
        taken.insert(pick);
    }
}

/// Why a set could not name this harness at all: `chief.engine.set` reads an
/// empty value, or the literal `default`, as "clear the choice" (its `set`
/// closure in ``engine_control``), so a profile acpmux calls either one can
/// never be switched to. The row says so rather than offer a choice that
/// silently keeps the harness the Chief already runs.
fn unnameable(id: &str) -> Option<String> {
    let trimmed = id.trim();
    (trimmed.is_empty() || trimmed == "default").then(|| {
        format!(
            "this Chief cannot be switched to a harness acpmux calls {:?}: a set reads that as \
             clearing the choice. Rename the profile in acpmux.",
            id
        )
    })
}

fn row(
    answer: &Value,
    id: &str,
    profile: &Value,
    catalog_name: Option<&str>,
    started_with: &BTreeMap<String, Family>,
    set_family: &impl Fn(&str) -> Family,
) -> Value {
    let str_of = |key: &str| {
        profile
            .get(key)
            .and_then(Value::as_str)
            .filter(|s| !s.is_empty())
    };
    // The gate the turn passes (harness_gate): acpmux's own unavailable
    // reason, a Claude adapter that is not acpmux's, a route with no profile.
    let plan = crate::harness_gate::plan(answer, id);
    let chief_family = plan.family;
    // A set checks the harness against the families this brain read at its
    // start, so a harness acpmux gained since would be refused with
    // `unknown_harness`. Say that here instead of offering a row the picker
    // cannot switch to.
    let reason = plan
        .admitted
        .err()
        .or_else(|| {
            (!started_with.is_empty() && !started_with.contains_key(id)).then(|| {
                format!(
                    "acpmux gained {id} after this Chief started; restart the Chief to run on it"
                )
            })
        })
        .or_else(|| unnameable(id));
    let family = str_of("family").unwrap_or(family_name(chief_family));
    let display = str_of("displayName").or(catalog_name).unwrap_or(id);

    let mut capabilities = Map::new();
    let declared = profile.get("capabilities").and_then(Value::as_object);
    for (key, value) in declared.into_iter().flatten() {
        if key != "effort" && !value.is_null() {
            capabilities.insert(key.clone(), value.clone());
        }
    }
    // The efforts the profile declares, less any a set would refuse
    // (`invalid_effort`); none left, or none declared, offers every one a set
    // accepts.
    let efforts: Vec<Value> = declared
        .and_then(|c| c.get("effort"))
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter(|e| {
            e.as_str()
                .is_some_and(|e| super::engine_control::EFFORTS.contains(&e))
        })
        .cloned()
        .collect();
    let efforts = if efforts.is_empty() {
        super::engine_control::EFFORTS
            .iter()
            .map(|e| json!(e))
            .collect()
    } else {
        efforts
    };
    capabilities.insert("efforts".into(), Value::Array(efforts));
    // The speeds a set would take, so the row never offers one it refuses: a
    // set checks against the start-up family (`Brain::family_of`), which a
    // harness whose family changed since no longer matches live.
    let speeds: Vec<&str> = crate::engine::SPEEDS
        .iter()
        .copied()
        .filter(|speed| crate::engine::check_speed(speed, set_family(id)).is_ok())
        .collect();
    capabilities.insert("speeds".into(), json!(speeds));

    let mut row = json!({
        "id": id,
        "displayName": display,
        "family": family,
        "chiefFamily": family_name(chief_family),
        "kind": str_of("kind").unwrap_or("acp"),
        "capabilities": capabilities,
        "unavailable": reason.is_some(),
    });
    if let Some(reason) = reason {
        row["unavailableReason"] = json!(reason);
    }
    for (key, value) in [
        ("description", str_of("description")),
        ("icon", str_of("icon")),
        (
            "login",
            profile.pointer("/auth/login").and_then(Value::as_str),
        ),
    ] {
        if let Some(value) = value {
            row[key] = json!(value);
        }
    }
    row
}

fn family_name(family: Family) -> &'static str {
    match family {
        Family::Claude => "claude",
        Family::Codex => "codex",
        Family::Other => "other",
    }
}
