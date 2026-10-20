//! Cloud subagents (plans/cmux-next/cloud-subagents-DESIGN.md, a242): with a
//! peer set, a subagent's session is created on that acpmux peer (a cloud
//! VM), and the live cap counts local subagents only.

mod common;

use std::path::PathBuf;
use std::sync::Arc;
use std::time::{Duration, Instant};

use common::*;
use optchat_chief::subagents::{CloudPlacement, Spawner, SubagentSettings};
use optchat_chief::tools::Orchestrator;

fn spawner(h: &Harness, cloud: Option<CloudPlacement>) -> Arc<Spawner> {
    Arc::new(
        Spawner::new(
            h.chat.clone(),
            h.agents.clone(),
            SubagentSettings {
                harness: "claude".into(),
                policy: "approve-all".into(),
                model: None,
                effort: None,
                preset: Some("optchat-sub-h0me".into()),
                cwd: h.dir.path().join("subagent"),
                prefix: "optchat-sub-h0me".into(),
                parent: optchat_chief::brain::PARENT.into(),
                claude_md: None,
            },
            h.tx.clone(),
            Arc::new(|_: &str| {}),
        )
        .with_cloud(cloud),
    )
}

fn cloud() -> CloudPlacement {
    CloudPlacement {
        peer: "cloud1".into(),
        dir: PathBuf::from("/home/agent/work"),
        harness: "claude".into(),
        instructions: "SUBAGENT SYSTEM TEXT".into(),
    }
}

fn run<T: Send + 'static>(h: &mut Harness, f: impl FnOnce() -> T + Send + 'static) -> T {
    let worker = std::thread::spawn(f);
    while !worker.is_finished() {
        if let Ok(input) = h.rx.recv_timeout(Duration::from_millis(10)) {
            h.brain.step(input);
        }
    }
    while let Ok(input) = h.rx.recv_timeout(Duration::from_millis(80)) {
        h.brain.step(input);
    }
    worker.join().unwrap()
}

fn wait_for(h: &mut Harness, what: impl Fn(&Harness) -> bool) {
    let until = Instant::now() + Duration::from_secs(5);
    while !what(h) && Instant::now() < until {
        if let Ok(input) = h.rx.recv_timeout(Duration::from_millis(10)) {
            h.brain.step(input);
        }
    }
    assert!(what(h), "timed out");
}

/// The subagent sessions' specs and the text of their first prompts.
fn subs(h: &Harness) -> Vec<(optchat_chief::acpmux::SessionSpec, String)> {
    let inner = h.agents.inner.lock().unwrap();
    inner
        .specs
        .iter()
        .enumerate()
        .filter(|(_, s)| s.tags.contains_key("optchat.subagent"))
        .map(|(k, s)| {
            let session = format!("s{}", k + 1);
            let prompt = inner
                .prompts
                .iter()
                .zip(&inner.prompt_sessions)
                .find(|(_, p)| **p == session)
                .map(|(b, _)| serde_json::to_string(b).unwrap())
                .unwrap_or_default();
            (s.clone(), prompt)
        })
        .collect()
}

#[test]
fn cloud_subagents_start_on_the_peer_and_take_no_local_slot() {
    let mut h = Harness::new(default_script());
    h.brain.set_max_live(Some(1));
    h.agents.hold(true);
    let sp = spawner(&h, Some(cloud()));
    h.brain.set_sub_starter(Some(sp.queue_starter()));
    let a = sp.clone();
    let spawned = run(&mut h, move || {
        a.spawn(
            vec!["build the thing".into(), "test the thing".into()],
            Some("~/fun/cmux".into()),
        )
    })
    .unwrap();
    assert!(spawned.contains("Started a1, a2"), "{spawned}");
    assert!(!spawned.contains("queued"), "{spawned}");
    assert!(
        spawned.contains("cloud1"),
        "the answer says where: {spawned}"
    );
    wait_for(&mut h, |h| {
        subs(h).iter().filter(|(_, p)| !p.is_empty()).count() >= 2
    });
    for (spec, prompt) in subs(&h) {
        assert_eq!(spec.peer.as_deref(), Some("cloud1"));
        assert_eq!(spec.cwd, PathBuf::from("/home/agent/work"));
        assert_eq!(spec.preset, None, "local presets do not exist on the peer");
        assert_eq!(spec.harness, "claude");
        assert!(spec.env.is_empty(), "{:?}", spec.env);
        assert!(prompt.contains("SUBAGENT SYSTEM TEXT"), "{prompt}");
        assert!(prompt.contains("cloud1"), "{prompt}");
        assert!(
            prompt.contains("~/src/cmux"),
            "its repo on the VM: {prompt}"
        );
    }

    // The two cloud subagents still run; a local one gets the one local slot.
    let local = spawner(&h, None);
    let b = local.clone();
    let spawned = run(&mut h, move || b.spawn(vec!["local task".into()], None)).unwrap();
    assert!(spawned.contains("Started a3"), "{spawned}");
    let specs = subs(&h);
    let a3 = specs.last().unwrap();
    assert_eq!(a3.0.peer, None);
    assert_eq!(a3.0.preset.as_deref(), Some("optchat-sub-h0me"));
}

#[test]
fn the_cloud_folder_names_the_repo_of_a_mac_path() {
    use optchat_chief::subagents::cloud_repo;
    assert_eq!(cloud_repo(Some("~/fun/cmux")), Some("cmux".into()));
    assert_eq!(
        cloud_repo(Some("/Users/lawrence/fun/cmuxterm-hq/")),
        Some("cmuxterm-hq".into())
    );
    assert_eq!(
        cloud_repo(Some("~/fun/cmux-worktrees/x")),
        Some("cmux".into()),
        "a worktree folder is its repo"
    );
    assert_eq!(cloud_repo(None), None);
}

#[test]
fn a_peer_session_names_its_peer_and_sends_only_an_asking_policy() {
    use optchat_chief::acpmux::{SessionSpec, session_meta};
    let mut spec = SessionSpec {
        name: "optchat-sub-h0me-a1".into(),
        cwd: PathBuf::from("/home/agent/work"),
        harness: "claude".into(),
        policy: "approve-all".into(),
        model: None,
        effort: None,
        preset: None,
        tags: Default::default(),
        env: Default::default(),
        fast: false,
        peer: Some("cloud1".into()),
    };
    let meta = session_meta(&spec, None);
    assert_eq!(meta["peer"], "cloud1");
    assert!(
        meta.get("policy").is_none(),
        "the VM's default applies: {meta}"
    );
    assert!(meta.get("preset").is_none());
    spec.policy = "ask".into();
    assert_eq!(
        session_meta(&spec, None)["policy"],
        "ask",
        "the spawn floor still asks"
    );
    spec.peer = None;
    spec.policy = "approve-all".into();
    let local = session_meta(&spec, Some("optchat-sub-h0me"));
    assert_eq!(local["policy"], "approve-all");
    assert!(local.get("peer").is_none());
}

/// `spawn(place)` picks the cloud peer or this host per call
/// (cloud-subagents-DESIGN.md, B2): UI and computer-use work stays local
/// while the peer is the default.
#[test]
fn spawn_place_picks_the_cloud_or_this_host_per_call() {
    let mut h = Harness::new(default_script());
    h.agents.hold(true);
    let sp = spawner(&h, Some(cloud()));
    h.brain.set_sub_starter(Some(sp.queue_starter()));
    let a = sp.clone();
    let spawned = run(&mut h, move || {
        a.spawn_placed(
            vec!["click the app".into()],
            None,
            None,
            Some("local".into()),
        )
    })
    .unwrap();
    assert!(spawned.contains("Started a1"), "{spawned}");
    assert!(!spawned.contains("cloud1"), "{spawned}");
    let a = sp.clone();
    let spawned = run(&mut h, move || {
        a.spawn_placed(vec!["build it".into()], None, None, Some("cloud".into()))
    })
    .unwrap();
    assert!(
        spawned.contains("Started a2 on the cloud VM cloud1"),
        "{spawned}"
    );
    let specs = subs(&h);
    assert_eq!(specs[0].0.peer, None, "place local: this host");
    assert_eq!(specs[0].0.preset.as_deref(), Some("optchat-sub-h0me"));
    assert_eq!(specs[1].0.peer.as_deref(), Some("cloud1"));
    let a = sp.clone();
    let bad = run(&mut h, move || {
        a.spawn_placed(vec!["x".into()], None, None, Some("moon".into()))
    });
    assert!(bad.is_err(), "{bad:?}");
}

/// `control cloud PEER` turns cloud subagents on with no env and no host
/// restart; it is saved in the host state; `control cloud off` turns it
/// off; `place: "cloud"` with no peer says how to set one up.
#[test]
fn control_cloud_sets_the_default_peer_at_run_time() {
    use optchat_chief::tools::ControlCall;
    let mut h = Harness::new(default_script());
    h.agents.hold(true);
    let sp = Arc::new(
        Arc::try_unwrap(spawner(&h, None))
            .ok()
            .unwrap()
            .with_cloud_text("SUBAGENT SYSTEM TEXT".into()),
    );
    h.brain.set_sub_starter(Some(sp.queue_starter()));

    let a = sp.clone();
    let none = run(&mut h, move || {
        a.spawn_placed(vec!["x".into()], None, None, Some("cloud".into()))
    });
    let none = none.unwrap_or_else(|e| e);
    assert!(none.contains("control cloud"), "says how: {none}");

    let a = sp.clone();
    let set = run(&mut h, move || {
        a.control(ControlCall {
            action: "cloud".into(),
            peer: Some("cloud2".into()),
            ..ControlCall::default()
        })
    })
    .unwrap();
    assert!(set.starts_with("outcome: done."), "{set}");
    assert_eq!(h.brain.state().cloud_peer.as_deref(), Some("cloud2"));
    let saved = serde_json::to_value(h.brain.state()).unwrap();
    assert_eq!(saved["cloud_peer"], "cloud2", "kept across a restart");

    let a = sp.clone();
    let spawned = run(&mut h, move || {
        a.spawn_placed(
            vec!["build it".into()],
            Some("~/fun/cmux".into()),
            None,
            None,
        )
    })
    .unwrap();
    assert!(spawned.contains("on the cloud VM cloud2"), "{spawned}");
    let a = sp.clone();
    let shown = run(&mut h, move || {
        a.control(ControlCall {
            action: "cloud".into(),
            ..ControlCall::default()
        })
    })
    .unwrap();
    assert!(shown.contains("cloud2"), "{shown}");

    let a = sp.clone();
    let off = run(&mut h, move || {
        a.control(ControlCall {
            action: "cloud".into(),
            peer: Some("off".into()),
            ..ControlCall::default()
        })
    })
    .unwrap();
    assert!(off.starts_with("outcome: done."), "{off}");
    let a = sp.clone();
    let spawned = run(&mut h, move || {
        a.spawn_placed(vec!["local now".into()], None, None, None)
    })
    .unwrap();
    assert!(!spawned.contains("cloud VM"), "{spawned}");

    let specs = subs(&h);
    let cloud_one = &specs[specs.len() - 2];
    assert_eq!(cloud_one.0.peer.as_deref(), Some("cloud2"));
    assert_eq!(cloud_one.0.cwd, PathBuf::from("/home/agent/work"));
    assert!(
        cloud_one.1.contains("SUBAGENT SYSTEM TEXT"),
        "{}",
        cloud_one.1
    );
    assert!(cloud_one.1.contains("~/src/cmux"), "{}", cloud_one.1);
    assert_eq!(specs.last().unwrap().0.peer, None);
}
