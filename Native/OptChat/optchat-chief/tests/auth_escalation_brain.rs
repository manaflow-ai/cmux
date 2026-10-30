//! A subagent's `escalate_auth` reaches its Chief at once: steered into a
//! running turn ahead of anything queued, never left as a stuck note; and
//! the flow ships as the first Chief skill (chief-skills-mcp-DESIGN.md).

mod common;

use std::sync::Arc;
use std::time::{Duration, Instant};

use common::*;
use optchat_chief::skills;
use optchat_chief::subagents::{Spawner, SubagentSettings};
use optchat_chief::tools::{AuthEscalation, Orchestrator, subagent_of_session};

fn spawner(h: &Harness) -> Arc<Spawner> {
    Arc::new(Spawner::new(
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
    ))
}

fn run<T: Send + 'static>(h: &mut Harness, f: impl FnOnce() -> T + Send + 'static) -> T {
    let worker = std::thread::spawn(f);
    while !worker.is_finished() {
        if let Ok(input) = h.rx.recv_timeout(Duration::from_millis(10)) {
            h.brain.step(input);
        }
    }
    worker.join().unwrap()
}

fn npm() -> AuthEscalation {
    AuthEscalation {
        site: "npmjs.com".into(),
        url: "https://www.npmjs.com/login".into(),
        reason: "add the cmux-tui nightly trusted publisher".into(),
        kind: "2fa".into(),
    }
}

#[test]
fn an_escalation_is_steered_into_the_running_chief_turn() {
    let mut h = Harness::new(default_script());
    h.agents.inner.lock().unwrap().steering = true;
    h.agents.hold(true);
    h.connect();
    let sp = spawner(&h);
    let a = sp.clone();
    run(&mut h, move || {
        a.spawn(vec!["publish the nightly".into()], None)
    })
    .unwrap();
    h.say("user_local", "how is the npm work going?");
    let deadline = Instant::now() + Duration::from_secs(10);
    while h
        .brain
        .state()
        .turn
        .as_ref()
        .and_then(|t| t.session_id.clone())
        .is_none()
    {
        assert!(Instant::now() < deadline, "the Chief turn never started");
        h.step();
    }

    let b = sp.clone();
    let answer = run(&mut h, move || b.escalate_auth("a1", &npm())).unwrap();
    assert!(answer.starts_with("outcome: done."), "{answer}");
    assert!(answer.contains("touch the sensor"), "{answer}");

    h.agents.wait_steers(1);
    let steers = h.agents.inner.lock().unwrap().steers.clone();
    let text = serde_json::to_string(&steers[0].1).unwrap();
    assert!(
        text.contains("[a1] needs a sign-in (2fa) on npmjs.com"),
        "{text}"
    );
    assert!(text.contains("chief-auth-escalation"), "{text}");
}

#[test]
fn only_a_known_subagent_escalates() {
    let mut h = Harness::new(default_script());
    h.connect();
    let sp = spawner(&h);
    let answer = run(&mut h, move || sp.escalate_auth("a9", &npm()));
    assert!(answer.unwrap_err().contains("no subagent a9"));
}

#[test]
fn the_subagent_id_comes_from_its_acpmux_session_name() {
    assert_eq!(
        subagent_of_session("optchat-sub-2e448bc2-a352").as_deref(),
        Some("a352")
    );
    assert_eq!(
        subagent_of_session("optchat-sub-h0me-a7-2").as_deref(),
        Some("a7"),
        "acpmux's suffix for a taken name"
    );
    assert_eq!(subagent_of_session("optchat-2e448bc2-6039"), None);
    assert_eq!(subagent_of_session("optchat-sub-a12345-x"), None);
}

#[test]
fn the_shipped_skill_installs_once_and_a_user_copy_is_kept() {
    let dir = tempfile::tempdir().unwrap();
    let shared = skills::shared_dir(&dir.path().join("default"));
    assert_eq!(shared, dir.path().join("skills"));

    let written = skills::install_builtin(&shared).unwrap();
    assert_eq!(
        written,
        vec![
            "chief-auth-escalation".to_owned(),
            "chief-cloud-machines".to_owned(),
            "cmux-adoption".to_owned(),
            "cmux-setup".to_owned(),
            "paid-plans".to_owned(),
        ]
    );
    // Every Chief signs in to GitHub by default (chief-github-DESIGN.md): the device code, a fresh one when it
    // ends (a self-wake timer), the token kept per Chief, and the granular options.
    // The skill ships in the GitHub tool pack (chief-toolpacks-DESIGN.md), not among the shared skills.
    assert!(!shared.join("github-signin").exists());
    let packs = optchat_chief::toolpacks::shared_dir(&dir.path().join("default"));
    optchat_chief::toolpacks::install_builtin(&packs).unwrap();
    let gh = std::fs::read_to_string(packs.join("github").join("SKILL.md")).unwrap();
    assert_eq!(skills::front_matter(&gh).unwrap().0, "github-signin");
    for word in [
        "chief-github login",
        "chief github login",
        "https://github.com/login/device",
        "chief-wake",
        "sleep",
        "3 hours",
        "fine-grained",
        "GitHub App",
        "chief github mac",
        "chief-github mac",
        "logout",
    ] {
        assert!(gh.contains(word), "{word}");
    }
    // Chiefs offer a paid plan by default when a task needs one (paid-product-DESIGN.md section 8).
    let paid = std::fs::read_to_string(shared.join("paid-plans").join("SKILL.md")).unwrap();
    let (name, description) = skills::front_matter(&paid).unwrap();
    assert_eq!(name, "paid-plans");
    assert!(description.contains("cloud.plan.required"), "{description}");
    assert!(paid.contains("cmux billing checkout --plan"), "{paid}");
    assert!(paid.contains("Never say you bought"), "{paid}");
    let path = shared.join("chief-auth-escalation").join("SKILL.md");
    let text = std::fs::read_to_string(&path).unwrap();
    let (name, description) = skills::front_matter(&text).unwrap();
    assert_eq!(name, "chief-auth-escalation");
    assert!(description.contains("Touch ID"), "{description}");
    assert!(
        skills::install_builtin(&shared).unwrap().is_empty(),
        "no rewrite"
    );

    // A stale managed copy is updated; one the user took over is kept.
    std::fs::write(
        &path,
        "---\nname: chief-auth-escalation\ndescription: old\ncmux-managed: true\n---\n",
    )
    .unwrap();
    assert_eq!(skills::install_builtin(&shared).unwrap().len(), 1);
    let mine = "---\nname: chief-auth-escalation\ndescription: my own steps\n---\nmine\n";
    std::fs::write(&path, mine).unwrap();
    assert!(skills::install_builtin(&shared).unwrap().is_empty());
    assert_eq!(std::fs::read_to_string(&path).unwrap(), mine);
}

#[test]
fn a_chief_skill_wins_over_a_shared_one_of_the_same_name() {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().join("default");
    let (shared, own) = (skills::shared_dir(&home), skills::chief_dir(&home));
    let put = |root: &std::path::Path, folder: &str, body: &str| {
        std::fs::create_dir_all(root.join(folder)).unwrap();
        std::fs::write(root.join(folder).join("SKILL.md"), body).unwrap();
    };
    put(
        &shared,
        "deploy",
        "---\nname: deploy\ndescription: shared deploy\n---\n",
    );
    put(
        &shared,
        "triage",
        "---\nname: triage\ndescription: shared triage\n---\n",
    );
    put(&shared, "broken", "no front matter\n");
    put(
        &own,
        "deploy",
        "---\nname: deploy\ndescription: this Chief's deploy\n---\n",
    );
    let got: Vec<(String, String)> = skills::load(&shared, &own)
        .into_iter()
        .map(|s| (s.name, s.description))
        .collect();
    assert_eq!(
        got,
        vec![
            ("deploy".to_owned(), "this Chief's deploy".to_owned()),
            ("triage".to_owned(), "shared triage".to_owned()),
        ]
    );
}
