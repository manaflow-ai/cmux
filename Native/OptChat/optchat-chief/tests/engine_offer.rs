//! chief.engine.get names the models and efforts the Chief can take: the
//! Home Chief Settings panel listed three hard-coded model ids whatever acpmux
//! offered (cx-miuo, ownership audit V-2). The models are acpmux's for the
//! engine's harness (`_acpmux/models`), the efforts the brain checks a set
//! against. chief.engine.set also takes the compactor's harness and model
//! (cosmic-gray 2026-10-14: a subrouter-only machine needs the compactor
//! off `claude`), and refuses a harness acpmux does not have.

mod common;

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixListener;
use std::sync::mpsc::channel;
use std::sync::{Arc, Mutex};

use optchat_chief::acpmux::{Acpmux, AgentEvent};
use optchat_chief::brain::{Brain, EngineRequest, Input, Settings};
use optchat_chief::state::StateFile;
use serde_json::{Value, json};

/// A fake acpmux whose `_acpmux/models` offers two harnesses.
fn serve(listener: UnixListener) {
    std::thread::spawn(move || {
        for conn in listener.incoming().flatten() {
            std::thread::spawn(move || {
                let mut out = conn.try_clone().unwrap();
                for line in BufReader::new(conn).lines() {
                    let Ok(line) = line else { return };
                    let req: Value = serde_json::from_str(&line).unwrap();
                    let id = req["id"].clone();
                    let result = match req["method"].as_str().unwrap_or("") {
                        "_acpmux/sessions" => json!({"sessions": []}),
                        "_acpmux/models" => json!({"harnesses": [
                            {"harness": "codex", "kind": "acp", "models": [
                                {"id": "gpt-6-sol", "name": "GPT-6 Sol"},
                            ]},
                            {"harness": "claude-sr", "kind": "claude-stdio", "models": [
                                {"id": "default", "name": "Default (Claude Code's choice)"},
                                {"id": "opus", "name": "Opus", "resolvedModel": "claude-opus-5-5"},
                                {"id": "claude-fable-5-1", "name": "Fable 5.1", "family": "Fable",
                                 "provider": "anthropic", "shortName": "Fable 5.1",
                                 "efforts": ["low", "medium", "high", "xhigh", "max"],
                                 "defaultEffort": "medium", "fast": true, "aliases": ["fable"],
                                 "contextWindow": 1000000, "releaseDate": "2026-08-01",
                                 "description": "Most capable", "curated": true,
                                 "cost": {"input": 15}},
                            ]},
                        ]}),
                        "_acpmux/harnesses" => harnesses(),
                        _ => json!({}),
                    };
                    writeln!(
                        out,
                        "{}",
                        json!({"jsonrpc": "2.0", "id": id, "result": result})
                    )
                    .unwrap();
                }
            });
        }
    });
}

/// The fake's `_acpmux/harnesses`: Claude Code through sr and directly,
/// a Claude ACP adapter the gate refuses, codex, an OpenCode whose launcher
/// is missing, the built-in UniiChat, and a terminal-only harness.
fn harnesses() -> Value {
    json!({
        "harnesses": {
            "claude-sr": {"kind": "claude-stdio", "argv": ["sr", "claude", "proxy"], "family": "claude"},
            "claude": {"kind": "claude-stdio", "argv": ["claude"], "family": "claude"},
            "claude-acp": {"kind": "acp", "argv": ["claude-code-acp"], "family": "claude"},
            "codex": {"kind": "acp", "argv": ["codex-acp"], "family": "codex"},
            "opencode": {"kind": "acp", "argv": ["opencode", "acp"], "family": "opencode",
                         "displayName": "OpenCode", "icon": "opencode",
                         // `none` is an effort acpmux takes and a Chief set does not.
                         "capabilities": {"effort": ["low", "none", "high"], "resume": true, "permissionModes": true},
                         "auth": {"login": "opencode auth login"},
                         "unavailable": "opencode is not on PATH"},
            "unii": {"kind": "acp", "argv": ["/Applications/cmux.app/acpmux", "uniichat-agent"],
                     "family": "unii", "displayName": "UniiChat",
                     "description": "UniiChat: one chat that never ends (uniichat.com)",
                     "capabilities": {"resume": true}},
            // The name `claude` and `claude-sr` get when they keep apart by
            // their ids, so the fallback has something to resolve...
            "claude-vm": {"kind": "claude-stdio", "argv": ["claude"], "family": "claude",
                          "displayName": "Claude Code (claude)"},
            // ...and `claude`'s own fallback to its id is taken too, so even
            // that has to give way.
            "claude-box": {"kind": "claude-stdio", "argv": ["claude"], "family": "claude",
                           "displayName": "claude"},
            // An empty catalog name is no name: this row falls back to its id.
            "nameless": {"kind": "acp", "argv": ["nameless"], "family": "other"},
            // A profile acpmux calls `default`, the word a set reads as clearing the choice.
            "default": {"kind": "acp", "argv": ["default-acp"], "family": "codex"},
            "aider": {"kind": "terminal", "argv": ["aider"], "family": "aider"},
        },
        "catalog": {"harnesses": [
            {"id": "claude", "name": "Claude Code", "profiles": ["claude", "claude-sr"]},
            {"id": "codex", "name": "Codex", "profiles": ["codex"]},
            {"id": "nameless", "name": "", "profiles": ["nameless"]},
        ]},
    })
}

/// A brain over the fake acpmux, its engine.json in `dir`, knowing
/// `families` (`_acpmux/harnesses` at host start).
fn brain(dir: &std::path::Path, families: &[(&str, optchat_chief::acpmux::Family)]) -> Brain {
    let socket = dir.join("acpmux.sock");
    serve(UnixListener::bind(&socket).unwrap());
    let acpmux = Acpmux::new(socket, None, Vec::new());
    let (events, up) = channel();
    let sink = Mutex::new(events);
    acpmux.spawn_link(
        Arc::new(move |e| {
            let _ = sink.lock().unwrap().send(e);
        }),
        Arc::new(|_: &str| {}),
    );
    while !matches!(up.recv_timeout(common::WAIT).unwrap(), AgentEvent::Up(_)) {}

    let settings = Settings {
        engine_file: Some(dir.join("engine.json")),
        families: families
            .iter()
            .map(|(name, family)| ((*name).to_owned(), *family))
            .collect(),
        ..common::settings(dir)
    };
    let (tx, _rx) = channel();
    Brain::new(
        common::open_chat(&dir.join("chat")),
        acpmux,
        settings,
        StateFile::new(&dir.join("host.json")),
        tx,
        Arc::new(|_: &str| {}),
    )
}

fn engine(brain: &mut Brain, request: EngineRequest) -> Value {
    let (reply, answer) = channel();
    brain.step(Input::Engine { request, reply });
    answer.recv_timeout(common::WAIT).unwrap()
}

#[test]
fn the_engine_answer_offers_the_harness_models_acpmux_has() {
    let dir = tempfile::tempdir().unwrap();
    let mut brain = brain(dir.path(), &[]);
    let answer = engine(&mut brain, EngineRequest::Show);

    assert_eq!(answer["engine"]["harness"], "claude-sr", "{answer:#}");
    let models: Vec<&str> = answer["offered"]["models"]
        .as_array()
        .unwrap_or_else(|| panic!("no offered models: {answer:#}"))
        .iter()
        .filter_map(|m| m["id"].as_str())
        .collect();
    assert_eq!(models, ["default", "opus", "claude-fable-5-1"]);
    assert_eq!(answer["offered"]["models"][2]["name"], "Fable 5.1");
    assert_eq!(
        answer["offered"]["efforts"],
        json!(["minimal", "low", "medium", "high", "xhigh", "max"])
    );
}

/// The Chief's model picker groups by family, dedupes aliases, offers only
/// the efforts a model takes and Fast where it runs: the answer keeps the
/// catalog metadata acpmux attached to each model (it kept only id and name).
#[test]
fn the_offered_models_keep_the_pickers_metadata() {
    let dir = tempfile::tempdir().unwrap();
    let mut brain = brain(dir.path(), &[]);
    let answer = engine(&mut brain, EngineRequest::Show);
    let fable = &answer["offered"]["models"][2];
    assert_eq!(fable["family"], "Fable", "{answer:#}");
    assert_eq!(fable["provider"], "anthropic");
    assert_eq!(fable["shortName"], "Fable 5.1");
    assert_eq!(
        fable["efforts"],
        json!(["low", "medium", "high", "xhigh", "max"])
    );
    assert_eq!(fable["defaultEffort"], "medium");
    assert_eq!(fable["fast"], true);
    assert_eq!(fable["aliases"], json!(["fable"]));
    assert_eq!(fable["contextWindow"], 1000000);
    assert_eq!(fable["releaseDate"], "2026-08-01");
    assert_eq!(fable["description"], "Most capable");
    // Prices and curation flags are not the picker's.
    assert_eq!(fable.get("cost"), None);
    assert_eq!(
        answer["offered"]["models"][1]["resolvedModel"],
        "claude-opus-5-5"
    );
}

/// The Speed picker shows Fast only where the turns' harness runs it (codex's
/// priority tier; Claude Code's adapter has none), as a set checks.
#[test]
fn the_offered_speeds_follow_the_turn_harness() {
    use optchat_chief::acpmux::Family;
    let dir = tempfile::tempdir().unwrap();
    let mut brain = brain(
        dir.path(),
        &[("claude-sr", Family::Claude), ("codex", Family::Codex)],
    );
    let answer = engine(&mut brain, EngineRequest::Show);
    assert_eq!(
        answer["offered"]["speeds"],
        json!(["default"]),
        "{answer:#}"
    );
    let codex = engine(
        &mut brain,
        EngineRequest::Set {
            harness: Some("codex".to_owned()),
            model: None,
            effort: None,
            speed: None,
            compactor_speed: None,
            compactor_harness: None,
            compactor_model: None,
            reactions: Default::default(),
        },
    );
    assert_eq!(
        codex["offered"]["speeds"],
        json!(["default", "fast"]),
        "{codex:#}"
    );
}

#[test]
fn the_engine_set_names_the_compactors_harness_and_model_acpmux_has() {
    use optchat_chief::acpmux::Family;
    let dir = tempfile::tempdir().unwrap();
    let mut brain = brain(
        dir.path(),
        &[
            ("claude", Family::Claude),
            ("claude-sr", Family::Claude),
            ("codex", Family::Codex),
        ],
    );
    let set = |compactor_harness: &str, compactor_model: Option<&str>| EngineRequest::Set {
        harness: None,
        model: None,
        effort: None,
        speed: None,
        compactor_speed: None,
        compactor_harness: Some(compactor_harness.to_owned()),
        compactor_model: compactor_model.map(str::to_owned),
        reactions: Default::default(),
    };

    let answer = engine(&mut brain, set("claude-sr", Some("claude-haiku-5-5")));
    assert_eq!(
        answer["engine"]["compactor_harness"], "claude-sr",
        "{answer:#}"
    );
    assert_eq!(
        answer["engine"]["compactor_model"], "claude-haiku-5-5",
        "{answer:#}"
    );
    let file = optchat_chief::engine::load(&dir.path().join("engine.json"));
    assert_eq!(file.compactor_harness.as_deref(), Some("claude-sr"));
    assert_eq!(file.compactor_model.as_deref(), Some("claude-haiku-5-5"));

    let refused = engine(&mut brain, set("no-such-harness", None));
    assert_eq!(refused["error"]["code"], "unknown_harness", "{refused:#}");
    assert_eq!(
        optchat_chief::engine::load(&dir.path().join("engine.json"))
            .compactor_harness
            .as_deref(),
        Some("claude-sr"),
        "a refused set writes nothing"
    );

    let cleared = engine(&mut brain, set("default", Some("default")));
    assert_eq!(
        cleared["engine"]["compactor_harness"],
        Value::Null,
        "{cleared:#}"
    );
    assert_eq!(
        cleared["engine"]["compactor_model"],
        Value::Null,
        "{cleared:#}"
    );
}

#[test]
fn a_chief_switches_its_turn_harness_to_uniichat_and_back() {
    use optchat_chief::acpmux::Family;
    let dir = tempfile::tempdir().unwrap();
    // acpmux's built-in `unii` (UniiChat through uniichat-agent) is an Other family.
    let mut brain = brain(
        dir.path(),
        &[
            ("claude-sr", Family::Claude),
            ("codex", Family::Codex),
            ("unii", Family::Other),
        ],
    );
    let set = |harness: &str| EngineRequest::Set {
        harness: Some(harness.to_owned()),
        model: None,
        effort: None,
        speed: None,
        compactor_speed: None,
        compactor_harness: None,
        compactor_model: None,
        reactions: Default::default(),
    };

    let answer = engine(&mut brain, set("unii"));
    assert_eq!(answer["engine"]["harness"], "unii", "{answer:#}");
    let file = optchat_chief::engine::load(&dir.path().join("engine.json"));
    assert_eq!(
        file.harness.as_deref(),
        Some("unii"),
        "the next turn runs on UniiChat"
    );
    // The compactor stays on Claude: UniiChat keeps its own memory, the
    // Chief's summaries still need a Claude route.
    assert_eq!(file.compactor_harness, None);

    let back = engine(&mut brain, set("default"));
    assert_eq!(back["engine"]["harness"], "claude-sr", "{back:#}");
    assert_eq!(
        optchat_chief::engine::load(&dir.path().join("engine.json")).harness,
        None
    );
}

/// The engine picker lists every harness a Chief turn can run on, from
/// acpmux's `_acpmux/harnesses` (Leo #89: "users choose the Chief's engine
/// ... each one lists what it supports"): its name, family, what it takes,
/// and why it cannot run when it cannot. A terminal-only harness never runs
/// a Chief turn and is not offered.
#[test]
fn the_engine_answer_offers_every_harness_with_what_it_supports() {
    use optchat_chief::acpmux::Family;
    let dir = tempfile::tempdir().unwrap();
    // The families this brain read at its start, which is what a set checks a
    // harness and its speed against, so the rows say what a set would take.
    let mut brain = brain(
        dir.path(),
        &[
            ("claude", Family::Claude),
            ("claude-acp", Family::Claude),
            ("claude-box", Family::Claude),
            ("claude-sr", Family::Claude),
            ("claude-vm", Family::Claude),
            ("codex", Family::Codex),
            ("default", Family::Codex),
            ("nameless", Family::Other),
            ("opencode", Family::Other),
            ("unii", Family::Other),
        ],
    );
    let answer = engine(&mut brain, EngineRequest::Show);
    let offered = answer["offered"]["harnesses"]
        .as_array()
        .unwrap_or_else(|| panic!("no offered harnesses: {answer:#}"));
    let ids: Vec<&str> = offered.iter().filter_map(|h| h["id"].as_str()).collect();
    assert_eq!(
        ids,
        [
            "claude",
            "claude-acp",
            "claude-box",
            "claude-sr",
            "claude-vm",
            "codex",
            "default",
            "nameless",
            "opencode",
            "unii"
        ],
        "{answer:#}"
    );
    let by_id = |id: &str| offered.iter().find(|h| h["id"] == id).unwrap();

    let codex = by_id("codex");
    assert_eq!(codex["displayName"], "Codex", "{codex:#}");
    assert_eq!(codex["family"], "codex");
    assert_eq!(codex["chiefFamily"], "codex");
    assert_eq!(codex["kind"], "acp");
    assert_eq!(codex["unavailable"], false);
    assert_eq!(codex.get("unavailableReason"), None);
    assert_eq!(codex["capabilities"]["speeds"], json!(["default", "fast"]));
    assert_eq!(
        codex["capabilities"]["efforts"],
        json!(["minimal", "low", "medium", "high", "xhigh", "max"])
    );

    // Two profiles of one catalog harness keep apart by their ids, and
    // claude-vm, which acpmux already calls "Claude Code (claude)", gives way
    // to its own id, so no two rows share a name.
    let sr = by_id("claude-sr");
    assert_eq!(sr["displayName"], "Claude Code (claude-sr)", "{sr:#}");
    assert_eq!(by_id("claude")["displayName"], "Claude Code (claude)");
    assert_eq!(by_id("claude-vm")["displayName"], "claude-vm", "{answer:#}");
    assert_eq!(sr["chiefFamily"], "claude");
    assert_eq!(sr["capabilities"]["speeds"], json!(["default"]));
    assert_eq!(sr["unavailable"], false);

    // A launcher acpmux could not find: listed, with acpmux's reason, the
    // profile's declared efforts and flags, and how to sign in.
    let opencode = by_id("opencode");
    assert_eq!(opencode["displayName"], "OpenCode", "{opencode:#}");
    assert_eq!(opencode["family"], "opencode");
    assert_eq!(opencode["chiefFamily"], "other");
    assert_eq!(opencode["icon"], "opencode");
    assert_eq!(opencode["unavailable"], true);
    assert!(
        opencode["unavailableReason"]
            .as_str()
            .is_some_and(|r| r.contains("opencode is not on PATH")),
        "{opencode:#}"
    );
    // `none` is dropped: a set refuses it, and the picker never offers what a
    // set refuses.
    assert_eq!(opencode["capabilities"]["efforts"], json!(["low", "high"]));
    assert_eq!(opencode["capabilities"]["resume"], true);
    assert_eq!(opencode["capabilities"]["permissionModes"], true);
    assert_eq!(opencode["capabilities"]["speeds"], json!(["default"]));
    assert_eq!(opencode["login"], "opencode auth login");

    // A Claude ACP adapter: the harness gate refuses it, and says why.
    let refused = by_id("claude-acp");
    assert_eq!(refused["unavailable"], true, "{refused:#}");
    assert!(
        refused["unavailableReason"]
            .as_str()
            .is_some_and(|r| r.contains("claude-stdio")),
        "{refused:#}"
    );

    // UniiChat: its own family, laid out as Other, with its description.
    let unii = by_id("unii");
    assert_eq!(unii["displayName"], "UniiChat", "{unii:#}");
    assert_eq!(unii["family"], "unii");
    assert_eq!(unii["chiefFamily"], "other");
    assert_eq!(
        unii["description"],
        "UniiChat: one chat that never ends (uniichat.com)"
    );
    assert_eq!(unii["unavailable"], false);
}

/// Every offered row is one a set would take: a harness acpmux gained after
/// this Chief started is listed unavailable, with how to get it, rather than
/// offered for a set that answers `unknown_harness`; a declared effort a set
/// refuses is left out rather than offered for an `invalid_effort`; and the
/// speeds are the start-up family's, which is the family a set checks, not
/// the family acpmux reports now.
#[test]
fn an_offer_never_names_a_harness_effort_or_speed_a_set_would_refuse() {
    use optchat_chief::acpmux::Family;
    let dir = tempfile::tempdir().unwrap();
    // The brain read only these at its start; acpmux lists unii and the rest
    // now, and it calls codex a Codex harness, which this brain did not read
    // it as.
    let mut brain = brain(
        dir.path(),
        &[
            ("claude-sr", Family::Claude),
            ("codex", Family::Other),
            ("default", Family::Codex),
        ],
    );
    let answer = engine(&mut brain, EngineRequest::Show);
    let offered = answer["offered"]["harnesses"].as_array().unwrap();
    let by_id = |id: &str| offered.iter().find(|h| h["id"] == id).unwrap();

    // Still listed, so the picker can say why, and still never offered as runnable.
    let unii = by_id("unii");
    assert_eq!(unii["unavailable"], true, "{unii:#}");
    assert!(
        unii["unavailableReason"]
            .as_str()
            .is_some_and(|r| r.contains("after this Chief started")),
        "{unii:#}"
    );
    // acpmux calls codex a Codex harness, whose Fast a set takes; this brain
    // read it as Other, which is what a set checks, so the row offers no Fast.
    let codex = by_id("codex");
    assert_eq!(codex["unavailable"], false, "{codex:#}");
    assert_eq!(
        codex["capabilities"]["speeds"],
        json!(["default"]),
        "{codex:#}"
    );

    let set =
        |harness: Option<&str>, effort: Option<&str>, speed: Option<&str>| EngineRequest::Set {
            harness: harness.map(str::to_owned),
            model: None,
            effort: effort.map(str::to_owned),
            speed: speed.map(str::to_owned),
            compactor_speed: None,
            compactor_harness: None,
            compactor_model: None,
            reactions: Default::default(),
        };
    // The reason each row gives is the refusal the set would answer.
    let refused = engine(&mut brain, set(Some("unii"), None, None));
    assert_eq!(refused["error"]["code"], "unknown_harness", "{refused:#}");
    let invalid = engine(&mut brain, set(None, Some("none"), None));
    assert_eq!(invalid["error"]["code"], "invalid_effort", "{invalid:#}");
    let slow = engine(&mut brain, set(Some("codex"), None, Some("fast")));
    assert_eq!(slow["error"]["code"], "invalid_speed", "{slow:#}");

    // A profile acpmux calls `default`: a set reads that value as clearing the
    // choice, so it never switches to the profile and keeps the harness the
    // Chief already runs. The row says so instead of offering a dead choice.
    let sentinel = by_id("default");
    assert_eq!(sentinel["unavailable"], true, "{sentinel:#}");
    assert!(
        sentinel["unavailableReason"]
            .as_str()
            .is_some_and(|r| r.contains("clearing the choice")),
        "{sentinel:#}"
    );
    // The set's answer is the dead choice the row warns about: no refusal, and
    // the harness it ran on before is still the one it runs on.
    let before = engine(&mut brain, EngineRequest::Show)["engine"]["harness"].clone();
    let cleared = engine(&mut brain, set(Some("default"), None, None));
    assert_eq!(cleared.get("error"), None, "{cleared:#}");
    assert_eq!(
        engine(&mut brain, EngineRequest::Show)["engine"]["harness"],
        before,
        "a set of the `default` profile switched nothing: {cleared:#}"
    );
}

/// Two profiles under one name keep apart by their ids, and a third profile
/// already called `Claude Code (claude)` does not leave two rows with that
/// name: the ones that would still share it fall back to their ids.
#[test]
fn no_two_rows_leave_the_picker_with_the_same_name() {
    use optchat_chief::acpmux::Family;
    let dir = tempfile::tempdir().unwrap();
    let mut brain = brain(dir.path(), &[("claude-sr", Family::Claude)]);
    let answer = engine(&mut brain, EngineRequest::Show);
    let offered = answer["offered"]["harnesses"].as_array().unwrap();
    let names: Vec<&str> = offered
        .iter()
        .filter_map(|h| h["displayName"].as_str())
        .collect();
    let mut unique = names.clone();
    unique.sort_unstable();
    unique.dedup();
    assert_eq!(
        unique.len(),
        names.len(),
        "duplicate picker names {names:?}: {answer:#}"
    );
    assert!(
        !names.iter().any(|n| n.is_empty()),
        "a blank picker name in {names:?}"
    );
    let by_id = |id: &str| offered.iter().find(|h| h["id"] == id).unwrap();
    // The shape the old two-pass disambiguation left two rows called
    // "claude" in: claude and claude-sr share "Claude Code", claude-vm is
    // already called "Claude Code (claude)", and claude-box is already called
    // "claude", the id claude would have fallen back to. Rows are taken in id
    // order, so claude keeps the parenthesised name and claude-vm gives way.
    assert_eq!(
        by_id("claude-sr")["displayName"],
        "Claude Code (claude-sr)",
        "{answer:#}"
    );
    assert_eq!(by_id("claude")["displayName"], "Claude Code (claude)");
    assert_eq!(by_id("claude-vm")["displayName"], "claude-vm", "{answer:#}");
    assert_eq!(by_id("claude-box")["displayName"], "claude");
    // An empty catalog name is no name.
    assert_eq!(by_id("nameless")["displayName"], "nameless");
}

/// The reaction classifier's fields (a416): a set saves them in engine.json,
/// the answer names the classifier this Chief runs (Claude Haiku and the
/// built-in prompt, "", by default), `default` clears them, and a
/// reactions_can_wake that is not a boolean is refused.
#[test]
fn the_engine_set_takes_the_reaction_classifier() {
    use optchat_chief::acpmux::Family;
    use optchat_chief::brain::ReactionFields;
    let dir = tempfile::tempdir().unwrap();
    let mut brain = brain(
        dir.path(),
        &[("claude", Family::Claude), ("claude-sr", Family::Claude)],
    );
    brain.set_reaction_user_settings(None);
    let set = |reactions: ReactionFields| EngineRequest::Set {
        harness: None,
        model: None,
        effort: None,
        speed: None,
        compactor_speed: None,
        compactor_harness: None,
        compactor_model: None,
        reactions: Box::new(reactions),
    };
    let shown = engine(&mut brain, EngineRequest::Show);
    assert_eq!(
        shown["engine"]["classifier_model"], "claude-haiku-5-5",
        "{shown:#}"
    );
    assert_eq!(shown["engine"]["classifier_prompt"], "", "{shown:#}");
    assert_eq!(shown["engine"]["reactions_can_wake"], true, "{shown:#}");
    let answer = engine(
        &mut brain,
        set(ReactionFields {
            classifier_harness: Some("claude-sr".into()),
            classifier_model: Some("claude-sonnet-5-5".into()),
            classifier_prompt: Some("Wake only on 👎.".into()),
            reactions_can_wake: Some("false".into()),
        }),
    );
    assert_eq!(
        answer["engine"]["classifier_harness"], "claude-sr",
        "{answer:#}"
    );
    assert_eq!(answer["engine"]["classifier_model"], "claude-sonnet-5-5");
    assert_eq!(answer["engine"]["classifier_prompt"], "Wake only on 👎.");
    assert_eq!(answer["engine"]["reactions_can_wake"], false);
    assert_eq!(answer["choice"]["reactions_can_wake"], false);
    let cleared = engine(
        &mut brain,
        set(ReactionFields {
            classifier_model: Some("default".into()),
            reactions_can_wake: Some("default".into()),
            ..ReactionFields::default()
        }),
    );
    assert_eq!(
        cleared["engine"]["classifier_model"], "claude-haiku-5-5",
        "{cleared:#}"
    );
    assert_eq!(cleared["engine"]["reactions_can_wake"], true);
    assert_eq!(
        cleared["engine"]["classifier_harness"], "claude-sr",
        "an absent field stays"
    );
    let refused = engine(
        &mut brain,
        set(ReactionFields {
            reactions_can_wake: Some("sometimes".into()),
            ..ReactionFields::default()
        }),
    );
    assert_eq!(refused["error"]["code"], "invalid_value", "{refused:#}");
    let unknown = engine(
        &mut brain,
        set(ReactionFields {
            classifier_harness: Some("nope".into()),
            ..ReactionFields::default()
        }),
    );
    assert_eq!(unknown["error"]["code"], "unknown_harness", "{unknown:#}");
}
