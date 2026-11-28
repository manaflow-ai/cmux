//! The shared behavior corpus (`cmux-chief-corpus/1`,
//! mux/packages/brain/conformance/chief-cases.json, generated from the
//! TypeScript brain) against optchat-chief's real code paths (cx-ebm.4,
//! decisions.md H8). The corpus traces the TypeScript core's effects; the
//! OptChat brain has other internals (one Chief conversation, OptChat memory
//! turns), so each case runs through one adapter that drives the real brain
//! and compares what both must share, or is N/A. The classification and
//! every recorded deviation live in the corpus README; a case missing from
//! it, or a deviation that no longer deviates, fails here: nothing is
//! skipped silently.
//!
//! - `inbox`: the conversation inputs go to the brain through its
//!   ConversationPort (snapshot, history, live changes); the messages it logs
//!   (wakes on) must be exactly the ones the corpus prompts.
//! - `turn-text`: each corpus turn's acpmux events run as one brain turn;
//!   the posted text must be the corpus's.
//! - `outbox`: the corpus's owner refusals of the first reply are replayed;
//!   the sends of that reply and the reconnect must match.

mod common;

use std::collections::{BTreeMap, BTreeSet};

use cmux_conversation::{Change, Message, Summary};
use common::*;
use optchat_chief::daemon::DaemonEvent;
use serde_json::{Value, json};

const CORPUS: &str = include_str!("../../../../mux/packages/brain/conformance/chief-cases.json");
const README: &str = include_str!("../../../../mux/packages/brain/conformance/README.md");

/// One difference: what the corpus expects (the key a recorded deviation
/// names) and what the brain did.
struct Mismatch {
    corpus: String,
    detail: String,
}

type Outcome = Vec<Mismatch>;

#[derive(Debug, Clone, PartialEq)]
enum Class {
    Inbox,
    TurnText,
    Outbox,
    NotApplicable,
}

/// The README's "optchat-chief" table: `| case | class | reason |`, and its
/// "Deviations" table: `| case | deviation |`.
fn readme() -> (BTreeMap<String, Class>, BTreeMap<String, Vec<String>>) {
    let mut classes = BTreeMap::new();
    let mut deviations = BTreeMap::new();
    let mut section = "";
    for line in README.lines() {
        if let Some(h) = line.strip_prefix("## ") {
            section = if h.starts_with("optchat-chief") {
                "classes"
            } else if h.starts_with("Deviations") {
                "deviations"
            } else {
                ""
            };
            continue;
        }
        let cells: Vec<&str> = line
            .trim()
            .trim_matches('|')
            .split(" | ")
            .map(str::trim)
            .collect();
        if !line.trim_start().starts_with('|')
            || cells.len() < 2
            || cells[0] == "case"
            || cells[0].starts_with("---")
        {
            continue;
        }
        match section {
            "classes" => {
                let class = match cells[1] {
                    "inbox" => Class::Inbox,
                    "turn-text" => Class::TurnText,
                    "outbox" => Class::Outbox,
                    "N/A" => Class::NotApplicable,
                    other => panic!("README: unknown class {other:?} for {}", cells[0]),
                };
                assert!(
                    class != Class::NotApplicable || cells.get(2).is_some_and(|r| !r.is_empty()),
                    "README: {} is N/A without a reason",
                    cells[0]
                );
                classes.insert(cells[0].to_owned(), class);
            }
            // `corpus expectation`: why optchat-chief differs.
            "deviations" => {
                let token = cells[1]
                    .strip_prefix('`')
                    .and_then(|r| r.split_once('`'))
                    .map(|(t, _)| t.to_owned())
                    .unwrap_or_else(|| {
                        panic!(
                            "README: deviation of {} names no corpus expectation",
                            cells[0]
                        )
                    });
                deviations
                    .entry(cells[0].to_owned())
                    .or_insert_with(Vec::new)
                    .push(token);
            }
            _ => {}
        }
    }
    (classes, deviations)
}

fn input_messages(input: &Value) -> Vec<Value> {
    match input["kind"].as_str() {
        Some("snapshot" | "history") => input["messages"].as_array().cloned().unwrap_or_default(),
        Some("conversation_changed") if input["change"]["kind"] == "message" => {
            vec![input["change"]["message"].clone()]
        }
        _ => Vec::new(),
    }
}

fn input_conversation(input: &Value) -> Option<String> {
    match input["kind"].as_str() {
        Some("snapshot" | "daemon_connected") => {
            input["conversation"]["id"].as_str().map(str::to_owned)
        }
        Some("history" | "conversation_changed") => {
            input["conversation"].as_str().map(str::to_owned)
        }
        _ => None,
    }
}

fn silent() -> Script {
    Box::new(|_, _| {
        vec![
            json!({"dir": "mux", "kind": "turn_started", "msg": {}}),
            json!({"dir": "mux", "kind": "turn_end", "msg": {}}),
        ]
    })
}

/// `inbox`: which messages of the Chief conversation (the corpus's first
/// connected conversation) wake the brain.
fn run_inbox(case: &Value) -> Result<Outcome, String> {
    let steps = case["steps"].as_array().unwrap();
    let default = steps
        .iter()
        .find(|s| s["input"]["kind"] == "daemon_connected")
        .and_then(|s| s["input"]["conversation"]["id"].as_str())
        .ok_or("no daemon_connected")?
        .to_owned();
    let mine = |s: &Value| input_conversation(&s["input"]).as_deref() == Some(default.as_str());
    // What the owner holds: every message the corpus's owner returns for the
    // Chief conversation, and its latest summary from a fetch.
    let mut first: Option<Summary> = None;
    let mut stored: BTreeMap<u64, Message> = BTreeMap::new();
    let mut live = Vec::new();
    for s in steps.iter().filter(|s| mine(s)) {
        let input = &s["input"];
        match input["kind"].as_str() {
            Some("daemon_connected") if first.is_none() => {
                first = Some(
                    serde_json::from_value(input["conversation"].clone())
                        .map_err(|e| e.to_string())?,
                )
            }
            Some("snapshot") => {
                first = Some(
                    serde_json::from_value(input["conversation"].clone())
                        .map_err(|e| e.to_string())?,
                )
            }
            _ => {}
        }
        for m in input_messages(input) {
            let m: Message = serde_json::from_value(m).map_err(|e| e.to_string())?;
            if input["kind"] == "conversation_changed" {
                live.push(m);
            } else {
                stored.insert(m.seq, m);
            }
        }
    }
    let mut summary = first.ok_or("no summary")?;
    // The corpus's `answered` prompts are durable in optchat-chief as the
    // agent read cursor (with logged_seq): nothing at or below it is logged
    // again.
    let answered = case["state"]["answered"]
        .as_array()
        .cloned()
        .unwrap_or_default();
    let known: Vec<&Message> = stored.values().chain(live.iter()).collect();
    if let Some(seq) = answered
        .iter()
        .filter_map(|id| id.as_str())
        .filter_map(|id| known.iter().find(|m| m.id == id).map(|m| m.seq))
        .max()
    {
        summary.read_cursors.insert("agent_mux".into(), seq);
    }
    let dir = tempfile::tempdir().unwrap();
    let owner = std::sync::Arc::new(std::sync::Mutex::new(Owner {
        summary: Some(summary.clone()),
        messages: stored.values().cloned().collect(),
        ..Owner::default()
    }));
    let mut h = Harness::in_dir(dir, silent(), owner.clone());
    h.connect();
    h.settle();
    for m in &live {
        {
            let mut o = owner.lock().unwrap();
            if !o.messages.iter().any(|x| x.seq == m.seq) {
                o.messages.push(m.clone());
                o.messages.sort_by_key(|x| x.seq);
            }
        }
        h.brain
            .step(optchat_chief::brain::Input::from(DaemonEvent::Changed {
                conversation: default.clone(),
                change: Change::Message { message: m.clone() },
            }));
        h.settle();
    }
    let all: Vec<Message> = owner.lock().unwrap().messages.clone();
    let logged: Vec<String> = h
        .log()
        .into_iter()
        .filter(|(k, _)| k == "user")
        .map(|(_, t)| t)
        .collect();
    let woke: BTreeSet<String> = all
        .iter()
        .filter(|m| {
            let text = cmux_chief::rules::message_text(m);
            !text.trim().is_empty() && logged.iter().any(|l| l.contains(text.trim()))
        })
        .map(|m| m.id.clone())
        .collect();
    let ids: BTreeSet<String> = all.iter().map(|m| m.id.clone()).collect();
    let expected: BTreeSet<String> = steps
        .iter()
        .flat_map(|s| s["effects"].as_array().cloned().unwrap_or_default())
        .filter(|e| e["kind"] == "prompt")
        .filter_map(|e| e["prompt_id"].as_str().map(str::to_owned))
        .filter(|id| ids.contains(id))
        .collect();
    Ok(if woke == expected {
        Vec::new()
    } else {
        vec![Mismatch {
            corpus: format!("prompts {expected:?}"),
            detail: format!("woke {woke:?}"),
        }]
    })
}

/// `turn-text`: each turn (turn_started to turn_end or turn_error) of the
/// corpus's mux session, run as one brain turn; the text the brain posts.
fn run_turn_text(case: &Value) -> Result<Outcome, String> {
    let steps = case["steps"].as_array().unwrap();
    let mut turns: Vec<(Vec<Value>, Option<String>)> = Vec::new();
    let mut current: Option<Vec<Value>> = None;
    for s in steps {
        let input = &s["input"];
        if input["kind"] == "acpmux_event" {
            let e = &input["event"];
            let mut event = json!({"dir": e["dir"], "kind": e["kind"], "msg": e["msg"]});
            if e["dir"] == "agent" {
                // The OptChat fold reads session updates as acpmux records them.
                event["dir"] = json!("in");
            }
            match e["kind"].as_str() {
                Some("turn_started") => current = Some(vec![event]),
                Some("turn_end" | "turn_error") => {
                    if let Some(mut events) = current.take() {
                        events.push(event);
                        let posted = s["effects"]
                            .as_array()
                            .unwrap()
                            .iter()
                            .find(|x| {
                                x["kind"] == "conversation_op" && x["op"]["kind"] == "message.send"
                            })
                            .and_then(|x| x["op"]["parts"][0]["text"].as_str())
                            .map(str::to_owned);
                        turns.push((events, posted));
                    }
                }
                _ => {
                    if let Some(events) = current.as_mut() {
                        events.push(event);
                    }
                }
            }
        }
    }
    let mut failures = Vec::new();
    for (events, expected) in turns {
        let events = std::sync::Arc::new(events);
        let script_events = events.clone();
        let mut h = Harness::new(Box::new(move |_, _| (*script_events).clone()));
        h.connect();
        h.say("user_local", "go");
        h.settle();
        let sends = h.owner.lock().unwrap().sends();
        let posted = sends.last().map(|(_, t)| t.clone());
        if posted != expected {
            failures.push(Mismatch {
                corpus: expected.unwrap_or_else(|| "nothing".into()),
                detail: format!("posted {posted:?} for events {events:?}"),
            });
        }
    }
    Ok(failures)
}

/// The refusal code inside an op_result reason ("conversation-op: agent_rate (...)").
fn reason_code(reason: &str) -> String {
    reason
        .split_once(": ")
        .map_or(reason, |(_, r)| r)
        .split(' ')
        .next()
        .unwrap_or_default()
        .to_owned()
}

/// `outbox`: the owner's answers to the first reply, replayed.
fn run_outbox(case: &Value) -> Result<Outcome, String> {
    let steps = case["steps"].as_array().unwrap();
    let key = steps
        .iter()
        .flat_map(|s| s["effects"].as_array().cloned().unwrap_or_default())
        .find(|e| e["kind"] == "conversation_op" && e["op"]["kind"] == "message.send")
        .and_then(|e| e["idempotency_key"].as_str().map(str::to_owned))
        .ok_or("no reply")?;
    let answers: Vec<Option<String>> = steps
        .iter()
        .map(|s| &s["input"])
        .filter(|i| i["kind"] == "op_result" && i["idempotency_key"] == key.as_str())
        .map(|i| i["reason"].as_str().map(reason_code))
        .collect();
    let expected_sends = steps
        .iter()
        .flat_map(|s| s["effects"].as_array().cloned().unwrap_or_default())
        .filter(|e| {
            e["kind"] == "conversation_op"
                && e["idempotency_key"] == key.as_str()
                && e["op"]["kind"] == "message.send"
        })
        .count();
    let expected_reconnect = steps
        .iter()
        .flat_map(|s| s["effects"].as_array().cloned().unwrap_or_default())
        .any(|e| e["kind"] == "reconnect");
    let mut h = Harness::new(default_script());
    h.owner.lock().unwrap().rejects = answers.iter().cloned().collect();
    h.connect();
    h.say("user_local", "hello");
    h.settle();
    let mut reconnected = false;
    for _ in 0..6 {
        if h.owner.lock().unwrap().reconnects > 0 && !reconnected {
            reconnected = true;
            h.connect();
            continue;
        }
        let Some(at) = h.brain.next_timer() else {
            break;
        };
        std::thread::sleep(at.saturating_duration_since(std::time::Instant::now()));
        h.brain.on_timer();
    }
    let first = h
        .owner
        .lock()
        .unwrap()
        .sends()
        .first()
        .map(|(k, _)| k.clone());
    let sends = h
        .owner
        .lock()
        .unwrap()
        .sends()
        .iter()
        .filter(|(k, _)| Some(k) == first.as_ref())
        .count();
    Ok(
        if sends == expected_sends && reconnected == expected_reconnect {
            Vec::new()
        } else {
            vec![Mismatch {
                corpus: format!("{expected_sends} sends, reconnect {expected_reconnect}"),
                detail: format!("answers {answers:?}: {sends} sends, reconnect {reconnected}"),
            }]
        },
    )
}

/// The corpus's `policy` cases through optchat-chief's entry points: its
/// settings file reader, its harness gate, and the shared turn-policy and
/// spawn-floor rules its brain calls (brain/turns.rs, brain/approvals.rs).
fn policy_result(function: &str, args: &Value) -> Value {
    let flag = |key: &str| args[key].as_bool().unwrap();
    match function {
        "remote_auto_approve" => {
            let dir = tempfile::tempdir().unwrap();
            let path = dir.path().join("settings.json");
            if !args["settings"].is_null() {
                std::fs::write(&path, args["settings"].to_string()).unwrap();
            }
            json!(optchat_chief::chief_settings::ChiefSettings::load(&path).remote_auto_approve)
        }
        "turn_policy" => json!(cmux_chief::policy::turn_policy(
            flag("remote"),
            flag("auto_approve"),
            args["configured"].as_str().unwrap()
        )),
        "spawn_floor" => json!(cmux_chief::policy::spawn_floor(
            flag("auto_approve"),
            flag("turn_ask"),
            flag("ask_child_live"),
            flag("ask_subagent_live")
        )),
        "harness_admit" => match optchat_chief::harness_gate::admit(
            &args["answer"],
            args["requested"].as_str().unwrap(),
        ) {
            Ok(a) => {
                let family = match a.family {
                    optchat_chief::acpmux::Family::Claude => "claude",
                    optchat_chief::acpmux::Family::Codex => "codex",
                    optchat_chief::acpmux::Family::Other => "other",
                };
                json!({"admitted": {"profile": a.profile, "kind": a.kind, "argv0": a.argv0, "family": family}})
            }
            Err(refused) => json!({ "refused": refused }),
        },
        other => panic!("unknown policy function {other}"),
    }
}

#[test]
fn the_shared_policy_cases_hold_for_optchat_chief() {
    let corpus: Value = serde_json::from_str(CORPUS).unwrap();
    let cases = corpus["policy"].as_array().cloned().unwrap_or_default();
    assert!(!cases.is_empty(), "the corpus has no policy cases");
    let failures: Vec<String> = cases
        .iter()
        .filter_map(|c| {
            let got = policy_result(c["fn"].as_str().unwrap(), &c["args"]);
            (got != c["result"]).then(|| format!("{}: want {} got {got}", c["name"], c["result"]))
        })
        .collect();
    assert!(failures.is_empty(), "{}", failures.join("\n"));
}

#[test]
fn the_shared_behavior_corpus_holds_for_optchat_chief() {
    let corpus: Value = serde_json::from_str(CORPUS).unwrap();
    let (classes, deviations) = readme();
    let mut failures = Vec::new();
    let mut ran = 0;
    for case in corpus["cases"].as_array().unwrap() {
        let name = case["name"].as_str().unwrap();
        let Some(class) = classes.get(name) else {
            failures.push(format!("not classified in the corpus README: {name}"));
            continue;
        };
        let result = match class {
            Class::Inbox => run_inbox(case),
            Class::TurnText => run_turn_text(case),
            Class::Outbox => run_outbox(case),
            Class::NotApplicable => continue,
        };
        ran += 1;
        let listed = deviations.get(name).cloned().unwrap_or_default();
        match result {
            Err(e) => failures.push(format!("{name}: the adapter failed: {e}")),
            Ok(mismatches) => {
                for token in &listed {
                    if !mismatches.iter().any(|m| &m.corpus == token) {
                        failures.push(format!(
                            "{name}: deviation `{token}` no longer deviates (remove it)"
                        ));
                    }
                }
                for m in mismatches {
                    if listed.contains(&m.corpus) {
                        println!(
                            "recorded deviation: {name}: corpus `{}`, {}",
                            m.corpus, m.detail
                        );
                    } else {
                        failures.push(format!("{name}: corpus `{}`, {}", m.corpus, m.detail));
                    }
                }
            }
        }
    }
    for name in classes.keys() {
        if !corpus["cases"]
            .as_array()
            .unwrap()
            .iter()
            .any(|c| c["name"] == name.as_str())
        {
            failures.push(format!(
                "README lists a case the corpus does not have: {name}"
            ));
        }
    }
    println!("{ran} corpus cases run against optchat-chief");
    assert!(ran >= 10, "too few cases run: {ran}");
    assert!(
        failures.is_empty(),
        "{} failures:\n{}",
        failures.len(),
        failures.join("\n")
    );
}
