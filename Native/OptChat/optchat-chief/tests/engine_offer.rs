//! chief.engine.get names the models and efforts the Chief can take: the
//! Home Chief Settings panel listed three hard-coded model ids whatever acpmux
//! offered (cx-miuo, ownership audit V-2). The models are acpmux's for the
//! engine's harness (`_acpmux/models`), the efforts the brain checks a set
//! against. chief.engine.set also takes the compactor's harness and model
//! (cosmic-gray 2026-10-14: a subrouter-only machine needs the compactor
//! off `claude`), and refuses a harness acpmux does not have.
//!
//! cosmic-gray 2026-10-21: `cmux chief engine` failed three times in a row
//! with "unavailable: Resource temporarily unavailable (os error 35)" (the
//! daemon's 10 s read deadline on the tools socket, as macOS reports it) and
//! the Settings panel read the running Chief as not running. The answer
//! asked acpmux for every peer's models too; acpmux waits up to 10 s for a
//! slow peer (models_fanout.rs `PEERS_BUDGET`), with the brain's one input
//! loop held the whole time. The turns run on a harness of this machine's
//! acpmux, so the answer and the probe ask that acpmux alone.

mod common;

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixListener;
use std::sync::mpsc::channel;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use optchat_chief::acpmux::{Acpmux, AgentEvent};
use optchat_chief::brain::{Brain, EngineRequest, Input, Settings};
use optchat_chief::state::StateFile;
use serde_json::{Value, json};

/// How long acpmux may wait on its peers' models (models_fanout.rs
/// `PEERS_BUDGET`), which is also how long the daemon waits for the brain's
/// answer (cmux-tui chief_control.rs `TIMEOUT`).
const PEERS_BUDGET: Duration = Duration::from_secs(10);

/// A fake acpmux whose `_acpmux/models` offers two harnesses. A request that
/// does not say `localOnly` also gets a peer's harness, after `fanout` (the
/// real acpmux asks its peers then, a slow one for up to `PEERS_BUDGET`).
fn serve(listener: UnixListener, fanout: Duration) {
    std::thread::spawn(move || {
        for conn in listener.incoming().flatten() {
            std::thread::spawn(move || {
                let mut out = conn.try_clone().unwrap();
                for line in BufReader::new(conn).lines() {
                    let Ok(line) = line else { return };
                    let req: Value = serde_json::from_str(&line).unwrap();
                    let id = req["id"].clone();
                    let peers = req["params"]["localOnly"] != json!(true);
                    let result = match req["method"].as_str().unwrap_or("") {
                        "_acpmux/sessions" => json!({"sessions": []}),
                        "_acpmux/models" if peers => {
                            std::thread::sleep(fanout);
                            let mut catalog = catalog();
                            catalog["harnesses"].as_array_mut().unwrap().push(json!(
                                {"harness": "huge-blue/claude-sr", "peer": "huge-blue",
                                 "kind": "claude-stdio", "models": [
                                    {"id": "sonnet", "name": "Sonnet"},
                                ]}
                            ));
                            catalog
                        }
                        "_acpmux/models" => catalog(),
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

/// This machine's harnesses in the fake's `_acpmux/models` answer.
fn catalog() -> Value {
    json!({"harnesses": [
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
    ]})
}

/// A brain over the fake acpmux, its engine.json in `dir`, knowing
/// `families` (`_acpmux/harnesses` at host start).
fn brain(dir: &std::path::Path, families: &[(&str, optchat_chief::acpmux::Family)]) -> Brain {
    brain_with(dir, families, Duration::ZERO)
}

/// [`brain`] over a fake acpmux whose peers take `fanout` to answer.
fn brain_with(
    dir: &std::path::Path,
    families: &[(&str, optchat_chief::acpmux::Family)],
    fanout: Duration,
) -> Brain {
    let socket = dir.join("acpmux.sock");
    serve(UnixListener::bind(&socket).unwrap(), fanout);
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

/// The ids of the answer's offered models.
fn offered(answer: &Value) -> Vec<&str> {
    answer["offered"]["models"]
        .as_array()
        .unwrap_or_else(|| panic!("no offered models: {answer:#}"))
        .iter()
        .filter_map(|m| m["id"].as_str())
        .collect()
}

/// A slow peer of acpmux never holds the answer: the daemon gives up on the
/// brain after `PEERS_BUDGET` and the owner reads a running Chief as gone.
#[test]
fn the_engine_answer_does_not_wait_on_acpmuxs_peers() {
    let dir = tempfile::tempdir().unwrap();
    let mut brain = brain_with(dir.path(), &[], PEERS_BUDGET + Duration::from_secs(2));
    let started = Instant::now();
    let answer = engine(&mut brain, EngineRequest::Show);
    let took = started.elapsed();
    assert!(
        took < PEERS_BUDGET / 2,
        "the answer waited {took:?} on acpmux's peers: {answer:#}"
    );
    assert_eq!(offered(&answer), ["default", "opus", "claude-fable-5-1"]);
}

/// A set probes the new harness and answers, both without the peers.
#[test]
fn the_engine_set_does_not_wait_on_acpmuxs_peers() {
    use optchat_chief::acpmux::Family;
    let dir = tempfile::tempdir().unwrap();
    let mut brain = brain_with(
        dir.path(),
        &[("claude-sr", Family::Claude), ("codex", Family::Codex)],
        PEERS_BUDGET + Duration::from_secs(2),
    );
    let started = Instant::now();
    let answer = engine(
        &mut brain,
        EngineRequest::Set {
            harness: Some("codex".to_owned()),
            model: None,
            effort: None,
            speed: None,
            compactor_speed: None,
            compactor_harness: None,
            compactor_model: None,
        },
    );
    let took = started.elapsed();
    assert!(
        took < PEERS_BUDGET / 2,
        "the set waited {took:?} on acpmux's peers: {answer:#}"
    );
    assert_eq!(answer["engine"]["harness"], "codex", "{answer:#}");
    assert_eq!(offered(&answer), ["gpt-6-sol"]);
}

/// A turn harness on one of acpmux's peers (`peer/harness`) still gets that
/// peer's models.
#[test]
fn a_peer_harness_still_offers_the_peers_models() {
    let dir = tempfile::tempdir().unwrap();
    let mut brain = brain(dir.path(), &[]);
    let answer = engine(
        &mut brain,
        EngineRequest::Set {
            harness: Some("huge-blue/claude-sr".to_owned()),
            model: None,
            effort: None,
            speed: None,
            compactor_speed: None,
            compactor_harness: None,
            compactor_model: None,
        },
    );
    assert_eq!(
        answer["engine"]["harness"], "huge-blue/claude-sr",
        "{answer:#}"
    );
    assert_eq!(offered(&answer), ["sonnet"]);
}
