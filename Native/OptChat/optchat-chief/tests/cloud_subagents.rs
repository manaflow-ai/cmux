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
fn a_cloud_subagent_is_told_how_its_commits_land_without_a_git_credential() {
    // The VM holds no GitHub credential: the subagent marks its worktree with
    // `git config cmux.land BRANCH`, and the Chief host's pool tool (cmuxterm-hq
    // tools/cloud-subagents deploy.sh land-requests) rebases and pushes it through
    // the Mac when the VM pauses at the final report.
    let text = cloud().task("a7", Some("~/fun/cmux"), "do it");
    assert!(
        text.contains("git -C /home/agent/work/a7 config cmux.land <branch>"),
        "{text}"
    );
    assert!(text.contains("never a token"), "{text}");
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
    h.brain.step(Input::CloudTick);
    let busy = vms.calls.lock().unwrap().clone();
    assert!(
        !busy.iter().any(|c| c.starts_with("pause")),
        "a1 lives: {busy:?}"
    );

    h.brain.step(Input::SubagentFailed {
        id: "a1".into(),
        error: "ended".into(),
    });
    h.brain.step(Input::CloudTick);
    h.brain.step(Input::CloudTick);
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

/// Records VM calls and the agent key files placed (cloud subagents' own sandbox keys).
#[derive(Default)]
struct KeyedVms {
    calls: std::sync::Mutex<Vec<String>>,
    files: std::sync::Mutex<Vec<(String, String, String)>>,
    refuse_keys: bool,
}

impl optchat_chief::cloud_vms::CloudVms for KeyedVms {
    fn resume(&self, peer: &str) -> Result<(), String> {
        self.calls.lock().unwrap().push(format!("resume {peer}"));
        Ok(())
    }
    fn pause(&self, peer: &str) -> Result<(), String> {
        self.calls.lock().unwrap().push(format!("pause {peer}"));
        Ok(())
    }
    fn put_agent_key(&self, peer: &str, agent: &str, file: &str) -> Result<(), String> {
        if self.refuse_keys {
            return Err("the pool tool cannot reach the VM".into());
        }
        self.files
            .lock()
            .unwrap()
            .push((peer.into(), agent.into(), file.into()));
        Ok(())
    }
    fn drop_agent_key(&self, peer: &str, agent: &str) -> Result<(), String> {
        self.calls
            .lock()
            .unwrap()
            .push(format!("drop {peer} {agent}"));
        Ok(())
    }
}

/// Issues `vmk_<agent>` and records revokes.
#[derive(Default)]
struct FakeKeys {
    revoked: std::sync::Mutex<Vec<String>>,
}

impl optchat_chief::agent_keys::AgentKeys for FakeKeys {
    fn issue(&self, agent: &str) -> Result<optchat_chief::agent_keys::AgentKey, String> {
        Ok(optchat_chief::agent_keys::AgentKey {
            id: format!("vmk_{agent}"),
            file: format!("{{\"key\":\"cmuxvm_sk_secret_{agent}\"}}\n"),
        })
    }
    fn revoke(&self, key_id: &str) -> Result<(), String> {
        self.revoked.lock().unwrap().push(key_id.into());
        Ok(())
    }
}

fn keyed_spawner(h: &Harness, vms: &Arc<KeyedVms>, keys: &Arc<FakeKeys>) -> Arc<Spawner> {
    let vms: Arc<dyn optchat_chief::cloud_vms::CloudVms> = vms.clone();
    let keys: Arc<dyn optchat_chief::agent_keys::AgentKeys> = keys.clone();
    Arc::new(
        Arc::try_unwrap(spawner(h, None))
            .ok()
            .unwrap()
            .with_cloud_text("SUBAGENT SYSTEM TEXT".into())
            .with_cloud_vms(Some(vms))
            .with_agent_keys(Some(keys)),
    )
}

/// A cloud subagent gets its own sandbox key: placed on its VM (never in its
/// task), named in its task, and revoked (the service then deletes its VMs)
/// once it is done; the file goes from the VM.
#[test]
fn a_cloud_subagent_gets_its_own_sandbox_key_and_loses_it_when_done() {
    use optchat_chief::brain::Input;
    let mut h = Harness::new(default_script());
    h.agents.hold(true);
    let vms = Arc::new(KeyedVms::default());
    let keys = Arc::new(FakeKeys::default());
    let sp = keyed_spawner(&h, &vms, &keys);
    h.brain.set_sub_starter(Some(sp.queue_starter()));
    h.brain
        .set_cloud_vms(Some(vms.clone()), Duration::from_secs(600));
    h.brain.set_agent_keys(Some(keys.clone()), Duration::ZERO);
    set_cloud(&mut h, &sp, "cloud1");

    let a = sp.clone();
    run(&mut h, move || a.spawn(vec!["one".into()], None)).unwrap();
    assert_eq!(
        vms.files.lock().unwrap().clone(),
        vec![(
            "cloud1".to_owned(),
            "a1".to_owned(),
            "{\"key\":\"cmuxvm_sk_secret_a1\"}\n".to_owned()
        )]
    );
    let task = subs(&h)[0].1.clone();
    assert!(
        task.contains("CMUX_AGENT_CONFIG=~/.config/cmux/agents/a1.json"),
        "{task}"
    );
    assert!(
        !task.contains("cmuxvm_sk_"),
        "the key never enters a prompt: {task}"
    );

    // Live: kept.
    h.brain.step(Input::CloudTick);
    assert!(keys.revoked.lock().unwrap().is_empty());

    h.brain.step(Input::SubagentFailed {
        id: "a1".into(),
        error: "ended".into(),
    });
    h.brain.step(Input::CloudTick);
    h.brain.step(Input::CloudTick);
    let until = Instant::now() + Duration::from_secs(5);
    while !vms
        .calls
        .lock()
        .unwrap()
        .contains(&"drop cloud1 a1".to_owned())
        && Instant::now() < until
    {
        std::thread::sleep(Duration::from_millis(10));
    }
    assert_eq!(
        keys.revoked.lock().unwrap().clone(),
        vec!["vmk_a1".to_owned()]
    );
    assert!(
        vms.calls
            .lock()
            .unwrap()
            .contains(&"drop cloud1 a1".to_owned())
    );
}

/// A key the pool tool could not place is revoked at once, and the subagent
/// starts without one (its task names no key file).
#[test]
fn an_unplaced_sandbox_key_is_revoked_and_the_subagent_starts_without_one() {
    let mut h = Harness::new(default_script());
    h.agents.hold(true);
    let vms = Arc::new(KeyedVms {
        refuse_keys: true,
        ..KeyedVms::default()
    });
    let keys = Arc::new(FakeKeys::default());
    let sp = keyed_spawner(&h, &vms, &keys);
    h.brain.set_sub_starter(Some(sp.queue_starter()));
    h.brain
        .set_cloud_vms(Some(vms.clone()), Duration::from_secs(600));
    set_cloud(&mut h, &sp, "cloud1");

    let a = sp.clone();
    let spawned = run(&mut h, move || a.spawn(vec!["one".into()], None)).unwrap();
    assert!(spawned.contains("Started a1"), "{spawned}");
    assert_eq!(
        keys.revoked.lock().unwrap().clone(),
        vec!["vmk_a1".to_owned()]
    );
    assert!(!subs(&h)[0].1.contains("CMUX_AGENT_CONFIG"));
}

// ---- One VM per subagent (cloud-subagents-DESIGN.md, "One VM per subagent") ----

/// Records provision/resume/pause/destroy; the first `refuse` destroys fail
/// (unpushed work on the VM).
#[derive(Default)]
struct PerAgentVms {
    refuse: std::sync::atomic::AtomicUsize,
    calls: std::sync::Mutex<Vec<String>>,
}

impl optchat_chief::cloud_vms::CloudVms for PerAgentVms {
    fn resume(&self, peer: &str) -> Result<(), String> {
        self.calls.lock().unwrap().push(format!("resume {peer}"));
        Ok(())
    }
    fn pause(&self, peer: &str) -> Result<(), String> {
        self.calls.lock().unwrap().push(format!("pause {peer}"));
        Ok(())
    }
    fn provision(&self, peer: &str, size: &str) -> Result<(), String> {
        self.calls
            .lock()
            .unwrap()
            .push(format!("provision {peer} {size}"));
        Ok(())
    }
    fn destroy(&self, peer: &str) -> Result<(), String> {
        self.calls.lock().unwrap().push(format!("destroy {peer}"));
        use std::sync::atomic::Ordering::SeqCst;
        if self.refuse.load(SeqCst) > 0 {
            self.refuse.fetch_sub(1, SeqCst);
            return Err("unpushed: ~/work/a1: 1 commits not pushed".into());
        }
        Ok(())
    }
}

fn per_agent(h: &mut Harness, vms: &Arc<PerAgentVms>) -> Arc<Spawner> {
    let dyn_vms: Arc<dyn optchat_chief::cloud_vms::CloudVms> = vms.clone();
    let sp = Arc::new(
        Arc::try_unwrap(spawner(h, None))
            .ok()
            .unwrap()
            .with_cloud_text("SUBAGENT SYSTEM TEXT".into())
            .with_cloud_vms(Some(dyn_vms.clone())),
    );
    h.brain.set_sub_starter(Some(sp.queue_starter()));
    h.brain
        .set_cloud_vms(Some(dyn_vms), Duration::from_secs(3600));
    set_cloud(h, &sp, optchat_chief::subagents::PER_AGENT);
    sp
}

fn calls_of(vms: &PerAgentVms) -> Vec<String> {
    vms.calls.lock().unwrap().clone()
}

/// `control cloud freestyle`: each subagent gets its own VM (its peer is
/// chief-sub-<id>), made at the size its task needs; a task that needs the
/// Mac (app UI, screenshots, computer use, sign-ins) stays on this host.
#[test]
fn each_cloud_subagent_gets_its_own_right_sized_vm_and_mac_tasks_stay_local() {
    let mut h = Harness::new(default_script());
    h.agents.hold(true);
    let vms = Arc::new(PerAgentVms::default());
    let sp = per_agent(&mut h, &vms);
    let a = sp.clone();
    let spawned = run(&mut h, move || {
        a.spawn(
            vec![
                "Design doc for cloud groups".into(),
                "Fix the web route and run bun test in web/".into(),
                "Screenshot the Home sidebar in the tagged app (reload.sh --launch)".into(),
            ],
            None,
        )
    })
    .unwrap();
    assert!(spawned.contains("Started a1, a2, a3"), "{spawned}");
    let peers: Vec<Option<String>> = subs(&h).into_iter().map(|(s, _)| s.peer).collect();
    assert_eq!(
        peers,
        vec![
            Some("chief-sub-a1".to_owned()),
            Some("chief-sub-a2".to_owned()),
            None,
        ]
    );
    let calls = calls_of(&vms);
    assert!(
        calls.contains(&"provision chief-sub-a1 small".to_owned()),
        "{calls:?}"
    );
    assert!(
        calls.contains(&"provision chief-sub-a2 medium".to_owned()),
        "{calls:?}"
    );
    assert!(!calls.iter().any(|c| c.contains("a3")), "{calls:?}");

    // An explicit size wins over the guess; `local` still means here.
    let a = sp.clone();
    run(&mut h, move || {
        a.spawn_placed(
            vec!["Write the README".into()],
            None,
            None,
            Some("cloud:large".into()),
        )
    })
    .unwrap();
    assert!(calls_of(&vms).contains(&"provision chief-sub-a4 large".to_owned()));
    let a = sp.clone();
    run(&mut h, move || {
        a.spawn_placed(
            vec!["Write the README".into()],
            None,
            None,
            Some("local".into()),
        )
    })
    .unwrap();
    assert_eq!(subs(&h).last().unwrap().0.peer, None);
}

/// A VM that cannot be made (over the daily budget, provider down) does not
/// lose the subagent: it starts on this host instead.
#[test]
fn a_subagent_whose_vm_cannot_be_made_starts_here() {
    struct NoVms;
    impl optchat_chief::cloud_vms::CloudVms for NoVms {
        fn resume(&self, _: &str) -> Result<(), String> {
            Ok(())
        }
        fn pause(&self, _: &str) -> Result<(), String> {
            Ok(())
        }
        fn provision(&self, _: &str, _: &str) -> Result<(), String> {
            Err("budget: a small VM would pass 20 USD/day".into())
        }
    }
    let mut h = Harness::new(default_script());
    h.agents.hold(true);
    let vms: Arc<dyn optchat_chief::cloud_vms::CloudVms> = Arc::new(NoVms);
    let sp = Arc::new(
        Arc::try_unwrap(spawner(&h, None))
            .ok()
            .unwrap()
            .with_cloud_text("T".into())
            .with_cloud_vms(Some(vms.clone())),
    );
    h.brain.set_sub_starter(Some(sp.queue_starter()));
    h.brain.set_cloud_vms(Some(vms), Duration::from_secs(3600));
    set_cloud(&mut h, &sp, optchat_chief::subagents::PER_AGENT);
    let a = sp.clone();
    let spawned = run(&mut h, move || a.spawn(vec!["Design doc".into()], None)).unwrap();
    assert!(spawned.contains("Started a1"), "{spawned}");
    assert!(spawned.contains("budget"), "says why: {spawned}");
    assert_eq!(subs(&h).last().unwrap().0.peer, None);
}

/// A finished subagent's own VM is deleted once its reap time passes; a
/// refusal (unpushed work) leaves it and tries again later; a tell after
/// the delete says so instead of reaching a VM that is gone.
#[test]
fn a_finished_subagents_vm_is_deleted_after_its_work_is_pushed() {
    use optchat_chief::brain::Input;
    let mut h = Harness::new(default_script());
    h.agents.hold(true);
    let vms = Arc::new(PerAgentVms::default());
    vms.refuse.store(1, std::sync::atomic::Ordering::SeqCst);
    let sp = per_agent(&mut h, &vms);
    h.brain.set_cloud_reap(Duration::ZERO);
    let a = sp.clone();
    run(&mut h, move || a.spawn(vec!["Design doc".into()], None)).unwrap();
    h.brain.step(Input::CloudTick);
    assert!(
        !calls_of(&vms).iter().any(|c| c.starts_with("destroy")),
        "a1 lives"
    );

    h.brain.step(Input::SubagentFailed {
        id: "a1".into(),
        error: "ended".into(),
    });
    let destroys = |v: &PerAgentVms| {
        calls_of(v)
            .iter()
            .filter(|c| *c == "destroy chief-sub-a1")
            .count()
    };
    let until = Instant::now() + Duration::from_secs(5);
    while destroys(&vms) < 2 && Instant::now() < until {
        h.brain.step(Input::CloudTick);
        while let Ok(input) = h.rx.recv_timeout(Duration::from_millis(20)) {
            h.brain.step(input);
        }
    }
    assert_eq!(
        destroys(&vms),
        2,
        "refused once, then deleted: {:?}",
        calls_of(&vms)
    );
    for _ in 0..3 {
        h.brain.step(Input::CloudTick);
        while let Ok(input) = h.rx.recv_timeout(Duration::from_millis(20)) {
            h.brain.step(input);
        }
    }
    assert_eq!(destroys(&vms), 2, "deleted once");
    let a = sp.clone();
    let told = run(&mut h, move || a.tell("a1", "one more thing"));
    let told = format!("{told:?}");
    assert!(told.contains("deleted"), "{told}");
}

/// Records the folder each workspace's terminal is opened in.
#[derive(Default)]
struct CwdRecorder {
    opened: std::sync::Mutex<Vec<PathBuf>>,
}

impl optchat_chief::workspaces::Workspaces for CwdRecorder {
    fn open(
        &self,
        key: &str,
        _session: &str,
        _name: &str,
        _group: &str,
        cwd: &std::path::Path,
    ) -> Result<String, String> {
        self.opened.lock().unwrap().push(cwd.to_path_buf());
        // The daemon spawns the terminal's shell in `cwd` (create-terminal):
        // a folder missing on this Mac fails the PTY spawn (a511, Oct 21:
        // "failed to spawn PTY command: No such file or directory").
        if !cwd.is_dir() {
            return Err("create-terminal: terminal launch failed: failed to spawn PTY command: No such file or directory (os error 2)".into());
        }
        Ok(key.to_owned())
    }
    fn rename(&self, _key: &str, _name: &str) -> Result<(), String> {
        Ok(())
    }
    fn place(&self) -> String {
        "the test".into()
    }
}

/// a511 (Oct 21): a cloud subagent got no cmux workspace, because its
/// workspace terminal was opened in the VM's folder (/home/agent/work),
/// which does not exist on the Mac. The session runs on the peer; the
/// terminal beside its chat runs here, so it opens in a local folder.
#[test]
fn a_cloud_subagents_workspace_terminal_opens_in_a_folder_on_this_mac() {
    let mut h = Harness::new(default_script());
    h.agents.hold(true);
    std::fs::create_dir_all(h.dir.path().join("subagent")).unwrap();
    let recorder = Arc::new(CwdRecorder::default());
    let ws: Arc<dyn optchat_chief::workspaces::Workspaces> = recorder.clone();
    h.brain.set_workspaces(Some(ws.clone()));
    // The VM's folder, missing on this host whatever it runs on: on a Linux
    // test host /home/agent/work may exist and hide the bug (a624, Oct 24).
    let vm_dir = h.dir.path().join("only-on-the-vm");
    let placement = CloudPlacement {
        dir: vm_dir.clone(),
        ..cloud()
    };
    let sp = Arc::new(
        Arc::try_unwrap(spawner(&h, Some(placement)))
            .ok()
            .unwrap()
            .with_workspaces(Some(ws)),
    );
    let a = sp.clone();
    let spawned = run(&mut h, move || {
        a.spawn(vec!["Title: Cloud thing\nbuild it".into()], None)
    })
    .unwrap();
    assert!(spawned.contains("Started a1"), "{spawned}");
    assert!(
        !spawned.contains("no cmux workspace"),
        "a cloud subagent gets its workspace: {spawned}"
    );
    let (spec, _) = subs(&h).into_iter().next().unwrap();
    assert_eq!(
        spec.cwd, vm_dir,
        "the session still runs in the VM's folder"
    );
    let opened = recorder.opened.lock().unwrap().clone();
    assert_eq!(opened.len(), 1, "{opened:?}");
    assert!(
        opened[0].is_dir(),
        "the terminal opens in a folder on this Mac: {:?}",
        opened[0]
    );
}

/// Records each workspace's name and group.
#[derive(Default)]
struct NameRecorder {
    opened: std::sync::Mutex<Vec<(String, String)>>,
}

impl optchat_chief::workspaces::Workspaces for NameRecorder {
    fn open(
        &self,
        key: &str,
        _session: &str,
        name: &str,
        group: &str,
        _cwd: &std::path::Path,
    ) -> Result<String, String> {
        self.opened
            .lock()
            .unwrap()
            .push((name.to_owned(), group.to_owned()));
        Ok(key.to_owned())
    }
    fn rename(&self, _key: &str, _name: &str) -> Result<(), String> {
        Ok(())
    }
    fn place(&self) -> String {
        "the test".into()
    }
}

/// Oct 22-25: 31 cloud subagents' workspaces read "You are a subagent of
/// Chief, an…" in the sidebar: the cloud placement puts the subagent
/// instructions before the task, and the workspace name and group were read
/// from that wrapped text, whose first lines are no `Title:`/`Group:`. They
/// come from the task the Chief wrote.
#[test]
fn a_cloud_subagents_workspace_is_named_and_grouped_by_its_task_headers() {
    let mut h = Harness::new(default_script());
    h.agents.hold(true);
    std::fs::create_dir_all(h.dir.path().join("subagent")).unwrap();
    let recorder = Arc::new(NameRecorder::default());
    let ws: Arc<dyn optchat_chief::workspaces::Workspaces> = recorder.clone();
    h.brain.set_workspaces(Some(ws.clone()));
    let sp = Arc::new(
        Arc::try_unwrap(spawner(
            &h,
            Some(CloudPlacement {
                instructions: "You are a subagent of Chief, an AI agent that works for one user."
                    .into(),
                ..cloud()
            }),
        ))
        .ok()
        .unwrap()
        .with_workspaces(Some(ws)),
    );
    let a = sp.clone();
    let spawned = run(&mut h, move || {
        a.spawn(
            vec!["Title: Cloud thing\nGroup: Agents & routing\n\nbuild it".into()],
            None,
        )
    })
    .unwrap();
    assert!(spawned.contains("Started a1"), "{spawned}");
    let opened = recorder.opened.lock().unwrap().clone();
    assert_eq!(
        opened,
        vec![("Cloud thing".to_owned(), "Agents & routing".to_owned())],
        "{spawned}"
    );
}

// ---- v2: every subagent in its own VM by default (cloud-subagents-DESIGN.md, "v2") ----

/// A spawner and brain with `vms` as the pool tool and no `control cloud`.
fn pool_unset(h: &mut Harness, vms: Arc<dyn optchat_chief::cloud_vms::CloudVms>) -> Arc<Spawner> {
    let sp = Arc::new(
        Arc::try_unwrap(spawner(h, None))
            .ok()
            .unwrap()
            .with_cloud_text("SUBAGENT SYSTEM TEXT".into())
            .with_cloud_vms(Some(vms.clone())),
    );
    h.brain.set_sub_starter(Some(sp.queue_starter()));
    h.brain.set_cloud_vms(Some(vms), Duration::from_secs(3600));
    sp
}

/// Cloud is the default: with a pool tool set up and no `control cloud`
/// ever saved, each subagent gets its own VM; a task that needs the Mac
/// stays here; `control cloud off` is remembered and wins.
#[test]
fn with_a_pool_tool_and_no_saved_choice_each_subagent_gets_its_own_vm() {
    let mut h = Harness::new(default_script());
    h.agents.hold(true);
    let vms = Arc::new(PerAgentVms::default());
    let sp = pool_unset(&mut h, vms.clone());
    let a = sp.clone();
    run(&mut h, move || {
        a.spawn(
            vec![
                "Design doc for cloud groups".into(),
                "Screenshot the Home sidebar in the tagged app".into(),
            ],
            None,
        )
    })
    .unwrap();
    let peers: Vec<Option<String>> = subs(&h).into_iter().map(|(s, _)| s.peer).collect();
    assert_eq!(peers, vec![Some("chief-sub-a1".to_owned()), None]);
    assert!(
        calls_of(&vms).contains(&"provision chief-sub-a1 small".to_owned()),
        "{:?}",
        calls_of(&vms)
    );

    set_cloud(&mut h, &sp, "off");
    let a = sp.clone();
    run(&mut h, move || {
        a.spawn(vec!["Write the README".into()], None)
    })
    .unwrap();
    assert_eq!(subs(&h).last().unwrap().0.peer, None, "off wins");
}

/// A pool tool that is not set up (no `vm-cmd`) leaves the default local.
#[test]
fn with_no_pool_tool_set_up_subagents_stay_here() {
    struct NotSetUp;
    impl optchat_chief::cloud_vms::CloudVms for NotSetUp {
        fn resume(&self, _: &str) -> Result<(), String> {
            Ok(())
        }
        fn pause(&self, _: &str) -> Result<(), String> {
            Ok(())
        }
        fn available(&self) -> bool {
            false
        }
    }
    let mut h = Harness::new(default_script());
    h.agents.hold(true);
    let sp = pool_unset(&mut h, Arc::new(NotSetUp));
    let a = sp.clone();
    run(&mut h, move || a.spawn(vec!["Design doc".into()], None)).unwrap();
    assert_eq!(subs(&h).last().unwrap().0.peer, None);
}

/// A subagent's own VM pauses as soon as its run ends (its final report),
/// not after `cloud.autoPauseIdleSeconds` (an hour here) and without a tick.
#[test]
fn a_subagents_own_vm_pauses_at_its_final_report() {
    use optchat_chief::brain::Input;
    let mut h = Harness::new(default_script());
    h.agents.hold(true);
    let vms = Arc::new(PerAgentVms::default());
    let sp = per_agent(&mut h, &vms);
    let a = sp.clone();
    run(&mut h, move || a.spawn(vec!["Design doc".into()], None)).unwrap();
    assert!(!calls_of(&vms).iter().any(|c| c.starts_with("pause")));
    h.brain.step(Input::SubagentFailed {
        id: "a1".into(),
        error: "ended".into(),
    });
    let until = Instant::now() + Duration::from_secs(5);
    while !calls_of(&vms).contains(&"pause chief-sub-a1".to_owned()) && Instant::now() < until {
        std::thread::sleep(Duration::from_millis(10));
    }
    assert!(
        calls_of(&vms).contains(&"pause chief-sub-a1".to_owned()),
        "{:?}",
        calls_of(&vms)
    );
}

/// A finished subagent's VM stays (paused) for `cloud.deleteAfterPausedDays`
/// (default 7) for a later tell, and is deleted after that; 30 minutes is no
/// longer enough.
#[test]
fn a_finished_subagents_vm_is_kept_paused_for_n_days_then_deleted() {
    use optchat_chief::brain::Input;
    use optchat_chief::chief_settings::ChiefSettings;
    assert_eq!(ChiefSettings::default().cloud_delete_after_paused_days, 7);
    let mut h = Harness::new(default_script());
    h.agents.hold(true);
    let vms = Arc::new(PerAgentVms::default());
    let sp = per_agent(&mut h, &vms);
    assert_eq!(
        h.brain.cloud_delete_after_paused(),
        Duration::from_secs(7 * 86_400)
    );
    let a = sp.clone();
    run(&mut h, move || a.spawn(vec!["Design doc".into()], None)).unwrap();
    h.brain.step(Input::SubagentFailed {
        id: "a1".into(),
        error: "ended".into(),
    });
    for _ in 0..3 {
        h.brain.step(Input::CloudTick);
        while let Ok(input) = h.rx.recv_timeout(Duration::from_millis(20)) {
            h.brain.step(input);
        }
    }
    assert!(
        !calls_of(&vms).iter().any(|c| c.starts_with("destroy")),
        "kept: {:?}",
        calls_of(&vms)
    );
    let set = h
        .brain
        .set_setting("cloud.deleteAfterPausedDays", "0")
        .unwrap();
    assert!(set.contains("cloud.deleteAfterPausedDays = 0"), "{set}");
    assert!(
        h.brain
            .set_setting("cloud.deleteAfterPausedDays", "soon")
            .is_err()
    );
    let until = Instant::now() + Duration::from_secs(5);
    while !calls_of(&vms).contains(&"destroy chief-sub-a1".to_owned()) && Instant::now() < until {
        h.brain.step(Input::CloudTick);
        while let Ok(input) = h.rx.recv_timeout(Duration::from_millis(20)) {
            h.brain.step(input);
        }
    }
    assert!(calls_of(&vms).contains(&"destroy chief-sub-a1".to_owned()));
}

/// A fleet whose jobs are in the given states.
#[derive(Default)]
struct FakeFleet {
    states: std::sync::Mutex<std::collections::BTreeMap<String, String>>,
}

impl optchat_chief::fleet_wait::FleetJobs for FakeFleet {
    fn state(&self, job: &str) -> Result<String, String> {
        Ok(self
            .states
            .lock()
            .unwrap()
            .get(job)
            .cloned()
            .unwrap_or_else(|| "queued".into()))
    }
}

#[test]
fn a_report_names_the_fleet_jobs_it_waits_on() {
    use optchat_chief::fleet_wait::waits;
    assert_eq!(
        waits(
            "Queued the build.\nfleet-wait: 366c8bc17202d2eedef8e092\n fleet-wait: 2bbb2f57c25c3543838ddac9 "
        ),
        vec![
            "366c8bc17202d2eedef8e092".to_owned(),
            "2bbb2f57c25c3543838ddac9".to_owned()
        ]
    );
    assert!(waits("fleet-wait: nope; rm -rf /").is_empty());
    assert!(waits("I will fleet-wait: 366c8bc17202d2eedef8e092 later").is_empty());
}

/// A cloud subagent that ends its turn on `fleet-wait: JOB` pauses (its VM)
/// while the job runs, with no turn for the Chief; when the job ends the
/// host resumes the VM and tells it the result.
#[test]
fn a_subagent_waiting_on_a_fleet_job_pauses_and_wakes_on_its_result() {
    use optchat_chief::brain::Input;
    use optchat_chief::state::SubStatus;
    const JOB: &str = "366c8bc17202d2eedef8e092";
    let mut h = Harness::new(Box::new(|turn, blocks| {
        let text = serde_json::to_string(blocks).unwrap();
        let say = if text.contains("finished: done") {
            "The build passed; landed.".to_owned()
        } else if text.contains("Build the app") {
            format!("Submitted the build.\nfleet-wait: {JOB}")
        } else {
            format!("answer {turn}")
        };
        vec![
            serde_json::json!({"dir": "mux", "kind": "turn_started", "msg": {}}),
            update(
                "agent_message_chunk",
                serde_json::json!({"content": {"type": "text", "text": say}}),
            ),
            serde_json::json!({"dir": "mux", "kind": "turn_end", "msg": {}}),
        ]
    }));
    let vms = Arc::new(PerAgentVms::default());
    let sp = per_agent(&mut h, &vms);
    let fleet = Arc::new(FakeFleet::default());
    h.brain.set_fleet_jobs(Some(fleet.clone()), Duration::ZERO);
    let a = sp.clone();
    run(&mut h, move || {
        a.spawn(vec!["Build the app on the fleet".into()], None)
    })
    .unwrap();
    let first = subs(&h)[0].1.clone();
    assert!(first.contains("fleet-wait: JOB_ID"), "the note: {first}");
    let waiting = |h: &Harness| {
        h.brain
            .state()
            .sub("a1")
            .is_some_and(|(_, s)| !s.fleet_wait.is_empty())
    };
    // Its turn ended: acpmux reports its session idle; the host reads its report.
    let session = h
        .brain
        .state()
        .sub("a1")
        .unwrap()
        .1
        .session_id
        .clone()
        .unwrap();
    let idle: cmux_chief::acp::SessionSummary = serde_json::from_value(serde_json::json!({
        "sessionId": session, "name": "a1", "status": "idle", "harness": "claude",
    }))
    .unwrap();
    let until = Instant::now() + Duration::from_secs(5);
    while !waiting(&h) && Instant::now() < until {
        h.brain.step(Input::from(
            optchat_chief::acpmux::AgentEvent::SessionChanged(idle.clone()),
        ));
        while let Ok(input) = h.rx.recv_timeout(Duration::from_millis(10)) {
            h.brain.step(input);
        }
    }
    let sub = h.brain.state().sub("a1").unwrap().1.clone();
    assert_eq!(sub.fleet_wait, vec![JOB.to_owned()]);
    assert!(sub.stopped, "no Chief turn while it waits: {sub:?}");
    let until = Instant::now() + Duration::from_secs(5);
    while !calls_of(&vms).contains(&"pause chief-sub-a1".to_owned()) && Instant::now() < until {
        std::thread::sleep(Duration::from_millis(10));
    }
    assert!(calls_of(&vms).contains(&"pause chief-sub-a1".to_owned()));

    // Still queued: nothing happens.
    for _ in 0..3 {
        h.brain.step(Input::CloudTick);
        while let Ok(input) = h.rx.recv_timeout(Duration::from_millis(20)) {
            h.brain.step(input);
        }
    }
    assert!(!calls_of(&vms).iter().any(|c| c == "resume chief-sub-a1"));

    fleet
        .states
        .lock()
        .unwrap()
        .insert(JOB.into(), "done".into());
    let woke = |h: &Harness| {
        subs(h)
            .iter()
            .any(|(_, p)| p.contains(&format!("fleet job {JOB} finished: done")))
            || h.agents.inner.lock().unwrap().prompts.iter().any(|b| {
                serde_json::to_string(b)
                    .unwrap()
                    .contains(&format!("fleet job {JOB} finished: done"))
            })
    };
    let until = Instant::now() + Duration::from_secs(5);
    while !woke(&h) && Instant::now() < until {
        h.brain.step(Input::CloudTick);
        while let Ok(input) = h.rx.recv_timeout(Duration::from_millis(20)) {
            h.brain.step(input);
        }
    }
    assert!(woke(&h), "told the result");
    assert!(
        calls_of(&vms).contains(&"resume chief-sub-a1".to_owned()),
        "{:?}",
        calls_of(&vms)
    );
    let sub = h.brain.state().sub("a1").unwrap().1.clone();
    assert!(sub.fleet_wait.is_empty());
    let _ = SubStatus::Done;
}
