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

/// Records VM calls in order.
#[derive(Default)]
struct FakeVms {
    calls: std::sync::Mutex<Vec<String>>,
}

impl optchat_chief::cloud_vms::CloudVms for FakeVms {
    fn resume(&self, peer: &str) -> Result<(), String> {
        self.calls.lock().unwrap().push(format!("resume {peer}"));
        Ok(())
    }
    fn pause(&self, peer: &str) -> Result<(), String> {
        self.calls.lock().unwrap().push(format!("pause {peer}"));
        Ok(())
    }
}

fn pool_spawner(h: &Harness, vms: &Arc<FakeVms>) -> Arc<Spawner> {
    let vms: Arc<dyn optchat_chief::cloud_vms::CloudVms> = vms.clone();
    Arc::new(
        Arc::try_unwrap(spawner(h, None))
            .ok()
            .unwrap()
            .with_cloud_text("SUBAGENT SYSTEM TEXT".into())
            .with_cloud_vms(Some(vms)),
    )
}

fn set_cloud(h: &mut Harness, sp: &Arc<Spawner>, peers: &str) {
    use optchat_chief::tools::ControlCall;
    let a = sp.clone();
    let peers = peers.to_owned();
    let set = run(h, move || {
        a.control(ControlCall {
            action: "cloud".into(),
            peer: Some(peers),
            ..ControlCall::default()
        })
    })
    .unwrap();
    assert!(set.starts_with("outcome: done."), "{set}");
}

/// B4: with several peers, each subagent goes to the peer with the fewest
/// live cloud subagents (ties: the first listed), and its VM is resumed
/// before its session starts.
#[test]
fn cloud_subagents_go_to_the_least_busy_peer_and_resume_its_vm() {
    let mut h = Harness::new(default_script());
    h.agents.hold(true);
    let vms = Arc::new(FakeVms::default());
    let sp = pool_spawner(&h, &vms);
    h.brain.set_sub_starter(Some(sp.queue_starter()));
    h.brain
        .set_cloud_vms(Some(vms.clone()), Duration::from_secs(600));
    set_cloud(&mut h, &sp, "cloud1,cloud2");

    let a = sp.clone();
    let spawned = run(&mut h, move || {
        a.spawn(vec!["one".into(), "two".into(), "three".into()], None)
    })
    .unwrap();
    assert!(spawned.contains("Started a1, a2, a3"), "{spawned}");
    let a = sp.clone();
    run(&mut h, move || a.spawn(vec!["four".into()], None)).unwrap();
    let peers: Vec<Option<String>> = subs(&h).into_iter().map(|(s, _)| s.peer).collect();
    assert_eq!(
        peers,
        vec![
            Some("cloud1".to_owned()),
            Some("cloud2".to_owned()),
            Some("cloud1".to_owned()),
            Some("cloud2".to_owned()),
        ],
        "least busy first"
    );
    let calls = vms.calls.lock().unwrap().clone();
    assert!(calls.contains(&"resume cloud1".to_owned()), "{calls:?}");
    assert!(calls.contains(&"resume cloud2".to_owned()), "{calls:?}");
    assert!(!calls.iter().any(|c| c.starts_with("pause")), "{calls:?}");
}

/// B4: a peer with no live cloud subagent for the idle time is paused once;
/// a new cloud subagent there resumes it first.
#[test]
fn an_idle_cloud_vm_is_paused_once_and_resumed_for_the_next_subagent() {
    use optchat_chief::brain::Input;
    let mut h = Harness::new(default_script());
    h.agents.hold(true);
    let vms = Arc::new(FakeVms::default());
    let sp = pool_spawner(&h, &vms);
    h.brain.set_sub_starter(Some(sp.queue_starter()));
    h.brain.set_cloud_vms(Some(vms.clone()), Duration::ZERO);
    set_cloud(&mut h, &sp, "cloud1");

    let a = sp.clone();
    run(&mut h, move || a.spawn(vec!["one".into()], None)).unwrap();
    h.brain.step(Input::SubTick);
    let busy = vms.calls.lock().unwrap().clone();
    assert!(
        !busy.iter().any(|c| c.starts_with("pause")),
        "a1 lives: {busy:?}"
    );

    h.brain.step(Input::SubagentFailed {
        id: "a1".into(),
        error: "ended".into(),
    });
    h.brain.step(Input::SubTick);
    h.brain.step(Input::SubTick);
    let until = Instant::now() + Duration::from_secs(5);
    while !vms
        .calls
        .lock()
        .unwrap()
        .contains(&"pause cloud1".to_owned())
        && Instant::now() < until
    {
        std::thread::sleep(Duration::from_millis(10));
    }
    let calls = vms.calls.lock().unwrap().clone();
    assert_eq!(
        calls.iter().filter(|c| *c == "pause cloud1").count(),
        1,
        "paused once: {calls:?}"
    );

    let a = sp.clone();
    run(&mut h, move || a.spawn(vec!["two".into()], None)).unwrap();
    let calls = vms.calls.lock().unwrap().clone();
    assert_eq!(
        calls.last().map(String::as_str),
        Some("resume cloud1"),
        "{calls:?}"
    );
}

/// Pause answers: the first `fail` pauses of a peer fail (the VM said busy).
#[derive(Default)]
struct BusyVms {
    fail: std::sync::atomic::AtomicUsize,
    calls: std::sync::Mutex<Vec<String>>,
}

impl optchat_chief::cloud_vms::CloudVms for BusyVms {
    fn resume(&self, peer: &str) -> Result<(), String> {
        self.calls.lock().unwrap().push(format!("resume {peer}"));
        Ok(())
    }
    fn pause(&self, peer: &str) -> Result<(), String> {
        self.calls.lock().unwrap().push(format!("pause {peer}"));
        use std::sync::atomic::Ordering::SeqCst;
        if self.fail.load(SeqCst) > 0 {
            self.fail.fetch_sub(1, SeqCst);
            return Err("busy: a background process runs".into());
        }
        Ok(())
    }
}

fn pauses(calls: &std::sync::Mutex<Vec<String>>, peer: &str) -> usize {
    calls
        .lock()
        .unwrap()
        .iter()
        .filter(|c| **c == format!("pause {peer}"))
        .count()
}

fn wait_calls(calls: &std::sync::Mutex<Vec<String>>, peer: &str, n: usize) {
    let until = Instant::now() + Duration::from_secs(5);
    while pauses(calls, peer) < n && Instant::now() < until {
        std::thread::sleep(Duration::from_millis(10));
    }
}

/// `cloud.autoPauseIdleSeconds` is 60 by default, a saved setting, and the
/// idle time the host pauses after (aggressive auto-pause).
#[test]
fn cloud_auto_pause_idle_seconds_is_60_by_default_and_a_setting() {
    use optchat_chief::chief_settings::ChiefSettings;
    assert_eq!(ChiefSettings::default().cloud_auto_pause_idle_secs, 60);
    let mut h = Harness::new(default_script());
    let file = h.dir.path().join("settings.json");
    assert_eq!(ChiefSettings::load(&file).cloud_auto_pause_idle_secs, 60);
    let set = h
        .brain
        .set_setting("cloud.autoPauseIdleSeconds", "0")
        .unwrap();
    assert!(set.contains("cloud.autoPauseIdleSeconds = 0"), "{set}");
    assert!(
        h.brain
            .set_setting("cloud.autoPauseIdleSeconds", "soon")
            .is_err()
    );

    // The brain pauses after the setting's idle time, not the one it was
    // built with.
    h.agents.hold(true);
    let vms = Arc::new(FakeVms::default());
    let sp = pool_spawner(&h, &vms);
    h.brain.set_sub_starter(Some(sp.queue_starter()));
    h.brain
        .set_cloud_vms(Some(vms.clone()), Duration::from_secs(3600));
    h.brain
        .set_setting("cloud.autoPauseIdleSeconds", "0")
        .unwrap();
    set_cloud(&mut h, &sp, "cloud1");
    let a = sp.clone();
    run(&mut h, move || a.spawn(vec!["one".into()], None)).unwrap();
    h.brain.step(optchat_chief::brain::Input::SubagentFailed {
        id: "a1".into(),
        error: "ended".into(),
    });
    h.brain.step(optchat_chief::brain::Input::CloudTick);
    h.brain.step(optchat_chief::brain::Input::CloudTick);
    wait_calls(&vms.calls, "cloud1", 1);
    assert_eq!(pauses(&vms.calls, "cloud1"), 1);
}

/// A VM the pool tool refuses to pause (a running process or turn there)
/// is tried again at a later tick, never marked paused.
#[test]
fn a_refused_pause_is_tried_again() {
    use optchat_chief::brain::Input;
    let mut h = Harness::new(default_script());
    h.agents.hold(true);
    let busy = Arc::new(BusyVms::default());
    busy.fail.store(1, std::sync::atomic::Ordering::SeqCst);
    let vms: Arc<dyn optchat_chief::cloud_vms::CloudVms> = busy.clone();
    let sp = Arc::new(
        Arc::try_unwrap(spawner(&h, None))
            .ok()
            .unwrap()
            .with_cloud_text("T".into())
            .with_cloud_vms(Some(vms.clone())),
    );
    h.brain.set_sub_starter(Some(sp.queue_starter()));
    h.brain.set_cloud_vms(Some(vms), Duration::ZERO);
    set_cloud(&mut h, &sp, "cloud1");
    let a = sp.clone();
    run(&mut h, move || a.spawn(vec!["one".into()], None)).unwrap();
    h.brain.step(Input::SubagentFailed {
        id: "a1".into(),
        error: "ended".into(),
    });
    h.brain.step(Input::CloudTick);
    h.brain.step(Input::CloudTick);
    wait_calls(&busy.calls, "cloud1", 1);
    // The refusal comes back to the brain; the next ticks try again.
    let until = Instant::now() + Duration::from_secs(5);
    while pauses(&busy.calls, "cloud1") < 2 && Instant::now() < until {
        while let Ok(input) = h.rx.recv_timeout(Duration::from_millis(20)) {
            h.brain.step(input);
        }
        h.brain.step(Input::CloudTick);
    }
    assert_eq!(
        pauses(&busy.calls, "cloud1"),
        2,
        "{:?}",
        busy.calls.lock().unwrap()
    );
}

/// The host going away pauses its idle cloud VMs at once (no idle wait),
/// and never one with a subagent mid-turn.
#[test]
fn host_shutdown_pauses_idle_cloud_vms_at_once_but_not_busy_ones() {
    use optchat_chief::brain::Input;
    let mut h = Harness::new(default_script());
    h.agents.hold(true);
    let vms = Arc::new(FakeVms::default());
    let sp = pool_spawner(&h, &vms);
    h.brain.set_sub_starter(Some(sp.queue_starter()));
    h.brain
        .set_cloud_vms(Some(vms.clone()), Duration::from_secs(3600));
    set_cloud(&mut h, &sp, "cloud1,cloud2");
    let a = sp.clone();
    run(&mut h, move || {
        a.spawn(vec!["one".into(), "two".into()], None)
    })
    .unwrap();
    // a1 (cloud1) ends; a2 (cloud2) is still mid-turn.
    h.brain.step(Input::SubagentFailed {
        id: "a1".into(),
        error: "ended".into(),
    });
    h.brain.step(Input::Shutdown { signal: 15 });
    assert_eq!(
        pauses(&vms.calls, "cloud1"),
        1,
        "{:?}",
        vms.calls.lock().unwrap()
    );
    assert_eq!(pauses(&vms.calls, "cloud2"), 0, "never mid-turn");
}
