use super::*;
use std::sync::Mutex;
use std::sync::atomic::{AtomicUsize, Ordering};

const HUB: &str = "https://hub.example";

/// A hub with one team list and counters; `redeem` writes the record a join would.
#[derive(Default)]
struct FakeHub {
    home: std::path::PathBuf,
    self_check: Mutex<Option<SelfCheck>>,
    rows: Mutex<Vec<(String, String, bool)>>,
    revoked: Mutex<Vec<String>>,
    mints: AtomicUsize,
    redeems: Mutex<Vec<(String, bool)>>,
    mint_fails: bool,
    redeem_wait: Option<std::time::Duration>,
    resumes: AtomicUsize,
    /// The record a pending join completes into when resumed, if any.
    resumed: Mutex<Option<MachineCredential>>,
    /// How many capability statements a sign-in started.
    statements: AtomicUsize,
    /// What the hub answers a revoke with the machine's own credential; Revoked when None.
    own_answer: Mutex<Option<leave::HubAnswer>>,
    /// The credentials each such revoke sent.
    own_revokes: Mutex<Vec<String>>,
}

impl FakeHub {
    fn at(home: &Path) -> Self {
        Self { home: home.to_owned(), ..Default::default() }
    }
}

impl EnrollHub for FakeHub {
    async fn check_self(&self, _: &MachineCredential) -> SelfCheck {
        self.self_check.lock().unwrap().unwrap_or(SelfCheck::Live)
    }
    async fn credentials(&self) -> Result<Vec<(String, String, bool)>> {
        Ok(self.rows.lock().unwrap().clone())
    }
    async fn revoke(&self, machine_id: &str) -> Result<()> {
        self.revoked.lock().unwrap().push(machine_id.to_owned());
        Ok(())
    }
    async fn mint(&self, label: &str) -> Result<Zeroizing<String>> {
        anyhow::ensure!(!self.mint_fails, "hub down");
        assert!(!label.is_empty());
        self.mints.fetch_add(1, Ordering::SeqCst);
        Ok(Zeroizing::new("cmj_fake".to_owned()))
    }
    async fn redeem(
        &self,
        name: &str,
        token: Zeroizing<String>,
        replace: bool,
        owner: &str,
    ) -> Result<()> {
        assert_eq!(token.as_str(), "cmj_fake");
        if let Some(wait) = self.redeem_wait {
            tokio::time::sleep(wait).await;
        }
        self.redeems.lock().unwrap().push((name.to_owned(), replace));
        let key = leave::node_key_for_join_at(&self.home)?.public_key_b64();
        save_at(
            &self.home,
            &MachineCredential {
                credential: "cmm_new".into(),
                machine_id: "machine_new".into(),
                team_id: "team".into(),
                name: name.to_owned(),
                hub_origin: HUB.into(),
                wg_public_key: key,
                credential_generation: 1,
                user_id: Some(owner.into()),
                host_fingerprint: Some("box-a".into()),
                joined_by: Some(JOINED_BY_SIGN_IN.into()),
                capabilities: Some(machine_capabilities()),
                ..Default::default()
            },
        )
    }
    async fn resume(&self) -> Result<()> {
        self.resumes.fetch_add(1, Ordering::SeqCst);
        let finished = self.resumed.lock().unwrap().take();
        match finished {
            Some(record) => save_at(&self.home, &record),
            None => Ok(()),
        }
    }
    fn repair_relay(&self) -> Result<()> {
        repair_relay_at(&self.home, HUB, Some("box-a"))
    }
    async fn revoke_own(&self, record: MachineCredential) -> leave::HubAnswer {
        self.own_revokes.lock().unwrap().push(record.credential);
        self.own_answer.lock().unwrap().clone().unwrap_or(leave::HubAnswer::Revoked)
    }
    fn state_capabilities(&self) {
        self.statements.fetch_add(1, Ordering::SeqCst);
    }
}

fn joined(home: &Path, edit: impl FnOnce(&mut MachineCredential)) {
    let mut record = MachineCredential {
        credential: "cmm_old".into(),
        machine_id: "machine_old".into(),
        team_id: "team".into(),
        name: "box".into(),
        hub_origin: HUB.into(),
        wg_public_key: "old-key".into(),
        credential_generation: 1,
        user_id: Some("user_me".into()),
        host_fingerprint: Some("box-a".into()),
        capabilities: Some(machine_capabilities()),
        ..Default::default()
    };
    edit(&mut record);
    save_at(home, &record).unwrap();
}

fn signed_in(record: &mut MachineCredential) {
    record.joined_by = Some(JOINED_BY_SIGN_IN.into());
}

fn relay_config(home: &Path) -> Option<Value> {
    let text = std::fs::read_to_string(home.join("config.json")).ok()?;
    serde_json::from_str::<Value>(&text).ok()?.get("meshRelay").cloned()
}

async fn sign_out(home: &Path, answer: leave::HubAnswer) -> LeaveOutcome {
    mark_leave(home, Some("user_me")).unwrap();
    leave_marked(home, Some("box-a"), false, move |_| {
        let answer = answer.clone();
        async move { answer }
    })
    .await
}

async fn enroll(home: &Path, port: &FakeHub) -> EnrollOutcome {
    enroll_at(home, HUB, "box", Some("user_me"), Some("box-a"), port).await
}

#[tokio::test]
async fn a_machine_never_joined_mints_and_redeems_once() {
    let home = tempfile::tempdir().unwrap();
    let port = FakeHub::at(home.path());
    assert_eq!(enroll(home.path(), &port).await, EnrollOutcome::Joined);
    assert_eq!(port.mints.load(Ordering::SeqCst), 1);
    assert_eq!(*port.redeems.lock().unwrap(), vec![("box".to_owned(), false)]);
    let record = load_at(home.path()).unwrap().unwrap();
    assert_eq!(record.joined_by.as_deref(), Some(JOINED_BY_SIGN_IN));
    // Signing in again: already joined, nothing minted.
    assert_eq!(enroll(home.path(), &port).await, EnrollOutcome::AlreadyJoined);
    assert_eq!(port.mints.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn an_already_joined_machine_mints_nothing_even_when_the_hub_is_down() {
    let home = tempfile::tempdir().unwrap();
    joined(home.path(), |_| {});
    let port = FakeHub::at(home.path());
    assert_eq!(enroll(home.path(), &port).await, EnrollOutcome::AlreadyJoined);
    *port.self_check.lock().unwrap() = Some(SelfCheck::Unavailable);
    assert_eq!(enroll(home.path(), &port).await, EnrollOutcome::AlreadyJoined);
    assert_eq!(port.mints.load(Ordering::SeqCst), 0);
    assert_eq!(load_at(home.path()).unwrap().unwrap().credential, "cmm_old");
}

#[tokio::test]
async fn a_revoked_machine_is_not_enrolled_again_on_its_own() {
    let home = tempfile::tempdir().unwrap();
    joined(home.path(), |r| r.revoked = true);
    let port = FakeHub::at(home.path());
    assert_eq!(enroll(home.path(), &port).await, EnrollOutcome::Revoked);
    // Revoked at the hub, not yet here: recorded, and still no enroll.
    let other = tempfile::tempdir().unwrap();
    joined(other.path(), |_| {});
    let port = FakeHub::at(other.path());
    *port.self_check.lock().unwrap() = Some(SelfCheck::Revoked);
    assert_eq!(enroll(other.path(), &port).await, EnrollOutcome::Revoked);
    assert!(load_at(other.path()).unwrap().unwrap().revoked);
    assert_eq!(port.mints.load(Ordering::SeqCst), 0);
}

#[tokio::test]
async fn a_credential_the_hub_never_knew_is_replaced() {
    let home = tempfile::tempdir().unwrap();
    joined(home.path(), |_| {});
    let port = FakeHub::at(home.path());
    *port.self_check.lock().unwrap() = Some(SelfCheck::Unknown);
    assert_eq!(enroll(home.path(), &port).await, EnrollOutcome::Joined);
    assert_eq!(*port.redeems.lock().unwrap(), vec![("box".to_owned(), true)]);
}

#[tokio::test]
async fn a_copied_home_enrolls_as_itself_and_never_revokes_the_original() {
    let home = tempfile::tempdir().unwrap();
    joined(home.path(), |r| r.host_fingerprint = Some("box-original".into()));
    let original_key =
        crate::cli::mesh_node_key::load_or_create_at(home.path()).unwrap().public_key_b64();
    let port = FakeHub::at(home.path());
    // The original box's live row carries the copied key.
    *port.rows.lock().unwrap() = vec![("machine_old".into(), original_key.clone(), false)];
    assert_eq!(enroll(home.path(), &port).await, EnrollOutcome::Joined);
    assert!(port.revoked.lock().unwrap().is_empty(), "the original's row stays");
    let record = load_at(home.path()).unwrap().unwrap();
    assert_eq!(record.machine_id, "machine_new");
    assert_ne!(record.wg_public_key, original_key, "this box has its own key");
}

#[tokio::test]
async fn another_persons_or_hubs_join_is_left_alone() {
    let home = tempfile::tempdir().unwrap();
    joined(home.path(), |r| r.user_id = Some("user_other".into()));
    let port = FakeHub::at(home.path());
    assert_eq!(enroll(home.path(), &port).await, EnrollOutcome::OtherUser);
    joined(home.path(), |r| r.hub_origin = "https://other.example".into());
    assert_eq!(enroll(home.path(), &port).await, EnrollOutcome::OtherHub);
    assert_eq!(port.mints.load(Ordering::SeqCst), 0);
    assert_eq!(load_at(home.path()).unwrap().unwrap().credential, "cmm_old");
}

#[tokio::test]
async fn only_the_row_a_sign_out_left_is_revoked_before_enrolling() {
    let home = tempfile::tempdir().unwrap();
    let key = crate::cli::mesh_node_key::load_or_create_at(home.path()).unwrap().public_key_b64();
    let port = FakeHub::at(home.path());
    *port.rows.lock().unwrap() = vec![
        ("machine_lost".into(), "old-key".into(), false),
        // This home's key on another row (a home copied before any join): never touched.
        ("machine_original".into(), key.clone(), false),
        ("machine_twin".into(), "twin-key".into(), false),
    ];
    // No sign-out left a row: nothing is revoked, whatever the keys say.
    assert_eq!(enroll(home.path(), &port).await, EnrollOutcome::Joined);
    assert!(port.revoked.lock().unwrap().is_empty());

    let home = tempfile::tempdir().unwrap();
    let port =
        FakeHub { rows: Mutex::new(port.rows.lock().unwrap().clone()), ..FakeHub::at(home.path()) };
    let lost = MachineCredential {
        machine_id: "machine_lost".into(),
        hub_origin: HUB.into(),
        host_fingerprint: Some("box-a".into()),
        ..Default::default()
    };
    record_stale(home.path(), &lost, false).unwrap();
    assert_eq!(enroll(home.path(), &port).await, EnrollOutcome::Joined);
    assert_eq!(*port.revoked.lock().unwrap(), vec!["machine_lost".to_owned()]);
    assert!(!to_revoke::any_queued(home.path()));
}

#[tokio::test]
async fn a_stale_row_from_another_box_is_not_revoked() {
    let home = tempfile::tempdir().unwrap();
    let port = FakeHub::at(home.path());
    *port.rows.lock().unwrap() = vec![("machine_lost".into(), "k".into(), false)];
    let other = MachineCredential {
        machine_id: "machine_lost".into(),
        hub_origin: HUB.into(),
        host_fingerprint: Some("box-original".into()),
        ..Default::default()
    };
    record_stale(home.path(), &other, false).unwrap();
    assert_eq!(enroll(home.path(), &port).await, EnrollOutcome::Joined);
    assert!(port.revoked.lock().unwrap().is_empty());
}

#[tokio::test]
async fn a_failed_mint_changes_nothing() {
    let home = tempfile::tempdir().unwrap();
    let port = FakeHub { mint_fails: true, ..FakeHub::at(home.path()) };
    assert_eq!(enroll(home.path(), &port).await, EnrollOutcome::Unavailable);
    assert!(load_at(home.path()).unwrap().is_none());
}

#[tokio::test]
async fn two_enrolls_at_once_mint_once() {
    let home = tempfile::tempdir().unwrap();
    let port = FakeHub {
        redeem_wait: Some(std::time::Duration::from_millis(400)),
        ..FakeHub::at(home.path())
    };
    let (a, b) = tokio::join!(enroll(home.path(), &port), enroll(home.path(), &port));
    let mut both = [a, b];
    both.sort_by_key(|o| format!("{o:?}"));
    assert_eq!(both, [EnrollOutcome::AlreadyJoined, EnrollOutcome::Joined]);
    assert_eq!(port.mints.load(Ordering::SeqCst), 1);
}

#[test]
fn a_redeem_always_says_whether_the_egress_proxy_runs() {
    assert_eq!(capabilities_for(true), vec!["vault.proxy.v1".to_owned()]);
    assert_eq!(capabilities_for(false), Vec::<String>::new());
    assert_eq!(machine_capabilities(), capabilities_for(RUNS_EGRESS_PROXY));
    // An empty list is sent, never left out (the hub reads a missing one as a legacy join).
    for capabilities in [capabilities_for(true), capabilities_for(false)] {
        let redeem: cmux_cloud_client::types::JoinRedeem = serde_json::from_value(json!({
            "token": "cmj_x", "platform": "linux", "hostname": "box", "wgPublicKey": "key",
            "capabilities": capabilities,
        }))
        .unwrap();
        assert_eq!(serde_json::to_value(redeem).unwrap()["capabilities"], json!(capabilities));
    }
}

#[tokio::test]
async fn an_empty_list_saved_after_a_409_changes_nothing_sent_and_states_nothing_again() {
    // `self_capabilities.rs` saves [] when the hub refused to widen a narrower list.
    let home = tempfile::tempdir().unwrap();
    joined(home.path(), |r| r.capabilities = Some(Vec::new()));
    // What this acpmux runs and sends comes from the build, never from the record.
    const { assert!(RUNS_EGRESS_PROXY, "the egress proxy runs whatever the record says") };
    assert_eq!(machine_capabilities(), vec!["vault.proxy.v1".to_owned()]);
    // A sign-in finds a list recorded: no statement of its own.
    let port = FakeHub::at(home.path());
    assert_eq!(enroll(home.path(), &port).await, EnrollOutcome::AlreadyJoined);
    assert_eq!(port.statements.load(Ordering::SeqCst), 0);
    assert_eq!(load_at(home.path()).unwrap().unwrap().capabilities, Some(Vec::new()));
}

#[tokio::test]
async fn a_legacy_credential_states_its_list_with_its_own_credential_and_is_never_rotated() {
    // A rotate the hub committed whose answer was lost would leave this machine with a
    // retired credential; a sign-in never rotates, so the joined credential stays the same.
    let home = tempfile::tempdir().unwrap();
    joined(home.path(), |r| r.capabilities = None);
    let port = FakeHub::at(home.path());
    assert_eq!(enroll(home.path(), &port).await, EnrollOutcome::AlreadyJoined);
    assert_eq!(port.statements.load(Ordering::SeqCst), 1);
    let record = load_at(home.path()).unwrap().unwrap();
    assert_eq!((record.credential.as_str(), record.credential_generation), ("cmm_old", 1));
    assert_eq!(record.capabilities, None, "the statement saves the hub's answer itself");
    assert_eq!(port.mints.load(Ordering::SeqCst), 0);
    // Its hub never answered: the next sign-in asks again, and still rotates nothing.
    assert_eq!(enroll(home.path(), &port).await, EnrollOutcome::AlreadyJoined);
    assert_eq!(port.statements.load(Ordering::SeqCst), 2);
    assert_eq!(load_at(home.path()).unwrap().unwrap().credential, "cmm_old");
}

/// A join proposal in `home` as `recovery::new_pending` writes it.
fn pending_join(home: &Path, joined_by: Option<&str>, fingerprint: &str) {
    pending_join_as(home, "cmm_pending", joined_by, fingerprint);
}

fn pending_join_as(home: &Path, credential: &str, joined_by: Option<&str>, fingerprint: &str) {
    let mut pending = json!({
        "version": 1, "credential": credential, "hub": HUB, "name": "box",
        "hostname": "box", "platform": "linux", "wg_public_key": "key", "prior": null,
        "host_fingerprint": fingerprint,
    });
    if let Some(joined_by) = joined_by {
        pending["joined_by"] = json!(joined_by);
        pending["owner"] = json!("user_me");
    }
    recovery::write_durable(
        &home.join("machine-join.pending.json"),
        &serde_json::to_vec(&pending).unwrap(),
        true,
    )
    .unwrap();
}

#[tokio::test]
async fn a_sign_out_retires_and_revokes_a_sign_in_join_left_pending() {
    // The sign-in's redeem landed, then its answer or probe failed: no record, a proposal.
    let home = tempfile::tempdir().unwrap();
    pending_join(home.path(), Some(JOINED_BY_SIGN_IN), "box-a");
    let asked = Mutex::new(Vec::new());
    let unanswered = |record: MachineCredential| {
        asked.lock().unwrap().push((record.credential.clone(), record.hub_origin.clone()));
        async { leave::HubAnswer::Unavailable("down".into()) }
    };
    mark_leave(home.path(), Some("user_me")).unwrap();
    let left = leave_marked(home.path(), Some("box-a"), false, unanswered).await;
    assert_eq!(left.kept, Some("notJoined"));
    assert_eq!(*asked.lock().unwrap(), vec![("cmm_pending".to_owned(), HUB.to_owned())]);
    // Set aside at once, so no sign-in (by anyone) resumes it as this person's join.
    assert!(!home.path().join("machine-join.pending.json").exists());
    assert!(to_revoke::any_queued(home.path()));
    // Not revoked yet: the mark stays, so the next start asks again.
    assert!(home.path().join(LEAVE_FILE).exists());
    let at_start =
        leave_marked(home.path(), Some("box-a"), true, |_| async { leave::HubAnswer::Revoked })
            .await;
    assert_eq!(at_start.kept, Some("notJoined"));
    assert!(relay_may_start(&at_start));
    assert!(!to_revoke::any_queued(home.path()));
    assert!(!home.path().join(LEAVE_FILE).exists());

    // A sign-in since cleared the mark: a start still revokes what was set aside, and the
    // new sign-in's own proposal stays.
    let home = tempfile::tempdir().unwrap();
    pending_join(home.path(), Some(JOINED_BY_SIGN_IN), "box-a");
    mark_leave(home.path(), Some("user_me")).unwrap();
    leave_marked(home.path(), Some("box-a"), false, |_| async {
        leave::HubAnswer::Unavailable("down".into())
    })
    .await;
    remove_mark(home.path(), LEAVE_FILE);
    pending_join(home.path(), Some(JOINED_BY_SIGN_IN), "box-a");
    let at_start = leave_marked(home.path(), Some("box-a"), true, |_| async {
        leave::HubAnswer::AlreadyGone { revoked: false }
    })
    .await;
    assert_eq!(at_start.kept, Some("signedIn"));
    assert!(!to_revoke::any_queued(home.path()));
    assert!(home.path().join("machine-join.pending.json").exists());

    // A pasted join line's proposal, and one copied from another box, are not this
    // sign-out's: they stay, and the hub is not asked.
    for (joined_by, fingerprint) in [(None, "box-a"), (Some(JOINED_BY_SIGN_IN), "box-b")] {
        let home = tempfile::tempdir().unwrap();
        pending_join(home.path(), joined_by, fingerprint);
        let calls = AtomicUsize::new(0);
        mark_leave(home.path(), Some("user_me")).unwrap();
        let left = leave_marked(home.path(), Some("box-a"), false, |_| {
            calls.fetch_add(1, Ordering::SeqCst);
            async { leave::HubAnswer::Revoked }
        })
        .await;
        assert_eq!(left.kept, Some("notJoined"));
        assert_eq!(calls.load(Ordering::SeqCst), 0);
        assert!(home.path().join("machine-join.pending.json").exists());
        assert!(!home.path().join(LEAVE_FILE).exists());
    }
}

#[tokio::test]
async fn a_leave_whose_local_cleanup_stopped_is_finished_not_read_as_a_revoke() {
    // `leave::remove_local` marked the record revoked, then stopped before removing it.
    let interrupted = |home: &Path| {
        joined(home, |r| {
            signed_in(r);
            r.revoked = true;
        });
        configure_mesh_relay_at(&home.join("config.json"), HUB).unwrap();
        mark_leave_removing(home).unwrap();
    };
    let home = tempfile::tempdir().unwrap();
    interrupted(home.path());
    // A second sign-out keeps saying the cleanup began.
    mark_leave(home.path(), Some("user_me")).unwrap();
    assert!(leave_removing(home.path()));
    let calls = AtomicUsize::new(0);
    let at_start = leave_marked(home.path(), Some("box-a"), true, |_| {
        calls.fetch_add(1, Ordering::SeqCst);
        async { leave::HubAnswer::Revoked }
    })
    .await;
    assert!(at_start.left, "{at_start:?}");
    assert_eq!(calls.load(Ordering::SeqCst), 0, "the hub was asked before the cleanup began");
    assert!(load_at(home.path()).unwrap().is_none());
    assert_eq!(relay_config(home.path()), None);
    assert!(!home.path().join(LEAVE_FILE).exists());
    // Signed in before any start finished it: the sign-in finishes it and enrolls.
    let home = tempfile::tempdir().unwrap();
    interrupted(home.path());
    let port = FakeHub::at(home.path());
    assert_eq!(enroll(home.path(), &port).await, EnrollOutcome::Joined);
    assert!(!home.path().join(LEAVE_FILE).exists());
    // A revoke at the hub (no cleanup begun) still keeps the machine out.
    let home = tempfile::tempdir().unwrap();
    joined(home.path(), |r| {
        signed_in(r);
        r.revoked = true;
    });
    mark_leave(home.path(), Some("user_me")).unwrap();
    let left =
        leave_marked(home.path(), Some("box-a"), false, |_| async { leave::HubAnswer::Revoked })
            .await;
    assert_eq!(left.kept, Some("revoked"));
    assert!(load_at(home.path()).unwrap().unwrap().revoked);
}

#[tokio::test]
async fn a_proposal_and_a_record_with_one_credential_are_revoked_once() {
    // `recovery::complete` wrote the record and stopped before removing the proposal.
    let home = tempfile::tempdir().unwrap();
    joined(home.path(), |r| {
        signed_in(r);
        r.credential = "cmm_pending".into();
    });
    pending_join(home.path(), Some(JOINED_BY_SIGN_IN), "box-a");
    let asked = Mutex::new(Vec::new());
    mark_leave(home.path(), Some("user_me")).unwrap();
    let left = leave_marked(home.path(), Some("box-a"), false, |record: MachineCredential| {
        asked.lock().unwrap().push(record.credential.clone());
        // A second revoke of the same credential would say someone revoked it.
        let first = asked.lock().unwrap().len() == 1;
        async move {
            if first {
                leave::HubAnswer::Revoked
            } else {
                leave::HubAnswer::AlreadyGone { revoked: true }
            }
        }
    })
    .await;
    assert!(left.left, "{left:?}");
    assert_eq!(*asked.lock().unwrap(), vec!["cmm_pending".to_owned()]);
    assert!(!to_revoke::revoked_on(home.path(), HUB, Some("box-a")), "no mark for its own revoke");
    let port = FakeHub::at(home.path());
    assert_eq!(enroll(home.path(), &port).await, EnrollOutcome::Joined);
}

#[tokio::test]
async fn another_persons_sign_in_finishes_the_last_persons_leave_then_enrolls() {
    // A's sign-in joined; the switch to B never reached acpmux as a sign-out.
    let home = tempfile::tempdir().unwrap();
    joined(home.path(), |r| {
        signed_in(r);
        r.user_id = Some("user_a".into());
    });
    configure_mesh_relay_at(&home.path().join("config.json"), HUB).unwrap();
    let port = FakeHub::at(home.path());
    assert_eq!(enroll(home.path(), &port).await, EnrollOutcome::Joined);
    assert_eq!(*port.own_revokes.lock().unwrap(), vec!["cmm_old".to_owned()]);
    let record = load_at(home.path()).unwrap().unwrap();
    assert_eq!(
        (record.machine_id.as_str(), record.user_id.as_deref()),
        ("machine_new", Some("user_me"))
    );
    assert!(!home.path().join(LEAVE_FILE).exists());

    // A's hub does not answer: A's join still goes here, and A's revoke stays on disk, asked
    // again with A's credential at each start and sign-in until the hub says it is revoked.
    let home = tempfile::tempdir().unwrap();
    joined(home.path(), |r| {
        signed_in(r);
        r.user_id = Some("user_a".into());
    });
    let port = FakeHub::at(home.path());
    *port.own_answer.lock().unwrap() = Some(leave::HubAnswer::Unavailable("down".into()));
    assert_eq!(enroll(home.path(), &port).await, EnrollOutcome::Joined);
    assert_eq!(load_at(home.path()).unwrap().unwrap().user_id.as_deref(), Some("user_me"));
    let stale = to_revoke::queued(home.path()).unwrap();
    assert_eq!(stale.len(), 1);
    assert_eq!(stale.first().unwrap().1.credential.as_deref(), Some("cmm_old"));
    // A start with the hub still down: asked again, kept.
    let at_start = leave_marked(home.path(), Some("box-a"), true, |_| async {
        leave::HubAnswer::Unavailable("down".into())
    })
    .await;
    assert!(relay_may_start(&at_start), "B's relay runs meanwhile");
    assert!(to_revoke::any_queued(home.path()));
    // The hub answers: revoked with A's own credential, and dropped.
    let asked = Mutex::new(Vec::new());
    leave_marked(home.path(), Some("box-a"), true, |record: MachineCredential| {
        asked.lock().unwrap().push(record.credential.clone());
        async { leave::HubAnswer::Revoked }
    })
    .await;
    assert_eq!(*asked.lock().unwrap(), vec!["cmm_old".to_owned()]);
    assert!(!to_revoke::any_queued(home.path()));
    assert_eq!(load_at(home.path()).unwrap().unwrap().user_id.as_deref(), Some("user_me"));

    // A's join made with a join line, or already revoked: left as it was.
    for edit in [
        (|r: &mut MachineCredential| r.user_id = Some("user_a".into()))
            as fn(&mut MachineCredential),
        |r| {
            signed_in(r);
            r.user_id = Some("user_a".into());
            r.revoked = true;
        },
    ] {
        let home = tempfile::tempdir().unwrap();
        joined(home.path(), edit);
        let port = FakeHub::at(home.path());
        assert_ne!(enroll(home.path(), &port).await, EnrollOutcome::Joined);
        assert!(port.own_revokes.lock().unwrap().is_empty());
        assert_eq!(load_at(home.path()).unwrap().unwrap().credential, "cmm_old");
    }
}

#[tokio::test]
async fn a_machine_revoked_at_the_hub_then_signed_out_is_not_enrolled_again() {
    let home = tempfile::tempdir().unwrap();
    joined(home.path(), signed_in);
    let gone = sign_out(home.path(), leave::HubAnswer::AlreadyGone { revoked: true }).await;
    assert!(gone.left);
    let port = FakeHub::at(home.path());
    assert_eq!(enroll(home.path(), &port).await, EnrollOutcome::Revoked);
    assert_eq!(port.mints.load(Ordering::SeqCst), 0);
    // The hub forgot it (never revoked): the next sign-in enrolls it.
    let home = tempfile::tempdir().unwrap();
    joined(home.path(), signed_in);
    sign_out(home.path(), leave::HubAnswer::AlreadyGone { revoked: false }).await;
    let port = FakeHub::at(home.path());
    assert_eq!(enroll(home.path(), &port).await, EnrollOutcome::Joined);
    // This sign-out revoked it itself: signing in again enrolls it.
    let home = tempfile::tempdir().unwrap();
    joined(home.path(), signed_in);
    sign_out(home.path(), leave::HubAnswer::Revoked).await;
    let port = FakeHub::at(home.path());
    assert_eq!(enroll(home.path(), &port).await, EnrollOutcome::Joined);
}

#[tokio::test]
async fn a_leave_cut_short_is_finished_at_the_next_start_before_the_relay() {
    let home = tempfile::tempdir().unwrap();
    joined(home.path(), signed_in);
    repair_relay_at(home.path(), HUB, Some("box-a")).unwrap();
    assert!(relay_config(home.path()).is_some());
    // The sign-out marked its leave and stopped there (no reply, or the daemon went).
    mark_leave(home.path(), Some("user_me")).unwrap();
    let asked = std::sync::atomic::AtomicBool::new(false);
    let revoked = &asked;
    let at_start = leave_marked(home.path(), Some("box-a"), true, move |_| async move {
        revoked.store(true, Ordering::SeqCst);
        leave::HubAnswer::Revoked
    })
    .await;
    assert!(at_start.left && revoked.load(Ordering::SeqCst));
    assert!(!relay_may_start(&at_start), "the relay is not started");
    assert_eq!(relay_config(home.path()), None);
    assert!(load_at(home.path()).unwrap().is_none());
    assert!(!home.path().join(LEAVE_FILE).exists());

    // Signed in again before the start: the mark is gone and the join stays.
    let home = tempfile::tempdir().unwrap();
    joined(home.path(), signed_in);
    mark_leave(home.path(), Some("user_me")).unwrap();
    let port = FakeHub::at(home.path());
    assert_eq!(enroll(home.path(), &port).await, EnrollOutcome::AlreadyJoined);
    asked.store(false, Ordering::SeqCst);
    let at_start = leave_marked(home.path(), Some("box-a"), true, move |_| async move {
        revoked.store(true, Ordering::SeqCst);
        leave::HubAnswer::Revoked
    })
    .await;
    assert_eq!(at_start.kept, Some("signedIn"));
    assert!(!asked.load(Ordering::SeqCst), "the hub is not asked");
    assert!(relay_may_start(&at_start));
    assert!(load_at(home.path()).unwrap().is_some());
}

#[tokio::test]
async fn a_joined_machine_missing_its_relay_config_is_repaired_without_minting() {
    let home = tempfile::tempdir().unwrap();
    joined(home.path(), |_| {});
    let port = FakeHub::at(home.path());
    assert_eq!(enroll(home.path(), &port).await, EnrollOutcome::AlreadyJoined);
    let relay = relay_config(home.path()).expect("meshRelay written");
    assert_eq!(relay["credential"], "join");
    assert_eq!(relay["url"], HUB);
    assert_eq!(port.mints.load(Ordering::SeqCst), 0);
    // A relay the person set up stays as it is.
    let home = tempfile::tempdir().unwrap();
    joined(home.path(), |_| {});
    std::fs::write(
        home.path().join("config.json"),
        json!({"meshRelay": {"url": "https://own.example", "tokenCommand": ["true"]}}).to_string(),
    )
    .unwrap();
    let port = FakeHub::at(home.path());
    assert_eq!(enroll(home.path(), &port).await, EnrollOutcome::AlreadyJoined);
    assert_eq!(relay_config(home.path()).unwrap()["url"], "https://own.example");
}

#[tokio::test]
async fn a_relay_the_person_set_up_survives_sign_in_enrollment_a_restart_and_sign_out() {
    let own = |url: &str| json!({"url": url, "tokenCommand": ["mint"]});
    let write = |home: &Path, relay: Value| {
        std::fs::write(home.join("config.json"), json!({"meshRelay": relay}).to_string()).unwrap();
    };
    // A working `tokenCommand` relay, to this hub or another, and no machine credential.
    for relay in [own("https://own.example"), own(HUB)] {
        let home = tempfile::tempdir().unwrap();
        write(home.path(), relay.clone());
        let port = FakeHub::at(home.path());
        assert_eq!(enroll(home.path(), &port).await, EnrollOutcome::OwnRelay);
        assert_eq!(port.mints.load(Ordering::SeqCst), 0, "no join is made to replace it");
        assert!(load_at(home.path()).unwrap().is_none());
        assert_eq!(relay_config(home.path()), Some(relay.clone()));
        // A restart: the start's leave and the next sign-in leave it as it is.
        let at_start =
            leave_marked(home.path(), Some("box-a"), true, |_| async { leave::HubAnswer::Revoked })
                .await;
        assert!(relay_may_start(&at_start));
        assert_eq!(enroll(home.path(), &port).await, EnrollOutcome::OwnRelay);
        assert_eq!(relay_config(home.path()), Some(relay.clone()));
        // Signing out: it is as it was.
        let left = sign_out(home.path(), leave::HubAnswer::Revoked).await;
        assert_eq!(left.kept, Some("notJoined"));
        assert_eq!(relay_config(home.path()), Some(relay));
    }

    // A sign-in's join the hub took before the relay was set up, finished after
    // (`recovery::complete`): joined, the relay untouched, and its sign-out keeps it.
    let home = tempfile::tempdir().unwrap();
    let relay = own("https://own.example");
    write(home.path(), relay.clone());
    joined(home.path(), signed_in);
    relay_for_join_at(&home.path().join("config.json"), HUB, true).unwrap();
    assert_eq!(relay_config(home.path()), Some(relay.clone()));
    let left = sign_out(home.path(), leave::HubAnswer::Revoked).await;
    assert!(left.left, "{left:?}");
    assert!(load_at(home.path()).unwrap().is_none());
    assert_eq!(relay_config(home.path()), Some(relay.clone()));
    // A join the person runs themselves writes the join's relay, as it always did.
    relay_for_join_at(&home.path().join("config.json"), HUB, false).unwrap();
    assert_eq!(relay_config(home.path()).unwrap()["credential"], "join");

    // A stray join relay with no record is the join's own: a sign-in enrolls over it, and
    // its sign-out removes only what it wrote.
    let home = tempfile::tempdir().unwrap();
    configure_mesh_relay_at(&home.path().join("config.json"), HUB).unwrap();
    let port = FakeHub::at(home.path());
    assert_eq!(enroll(home.path(), &port).await, EnrollOutcome::Joined);
    relay_for_join_at(&home.path().join("config.json"), HUB, true).unwrap();
    assert!(sign_out(home.path(), leave::HubAnswer::Revoked).await.left);
    assert_eq!(relay_config(home.path()), None);
}

#[tokio::test]
async fn a_join_credential_relay_for_another_hub_survives_a_sign_out_of_the_automatic_join() {
    let other = json!({"url": "https://other.example", "credential": "join"});
    let home = tempfile::tempdir().unwrap();
    std::fs::write(home.path().join("config.json"), json!({"meshRelay": other}).to_string())
        .unwrap();
    joined(home.path(), signed_in);
    // The enroll's rule reads it as the person's own, and so does the leave's.
    assert!(own_relay_at(&home.path().join("config.json"), HUB).unwrap());
    let left = sign_out(home.path(), leave::HubAnswer::Revoked).await;
    assert!(left.left, "{left:?}");
    assert!(load_at(home.path()).unwrap().is_none());
    assert_eq!(relay_config(home.path()), Some(other.clone()));

    // A leave cut short after marking the record revoked, finished at the next start: the
    // same rule, so that relay still stays.
    let home = tempfile::tempdir().unwrap();
    std::fs::write(home.path().join("config.json"), json!({"meshRelay": other}).to_string())
        .unwrap();
    joined(home.path(), signed_in);
    mark_leave_removing(home.path()).unwrap();
    leave::remove_local(home.path(), false).unwrap();
    assert_eq!(relay_config(home.path()), Some(other));

    // The relay this join wrote, for the record's hub, is the one a sign-out removes.
    let home = tempfile::tempdir().unwrap();
    configure_mesh_relay_at(&home.path().join("config.json"), HUB).unwrap();
    joined(home.path(), signed_in);
    assert!(!own_relay_at(&home.path().join("config.json"), HUB).unwrap());
    assert!(sign_out(home.path(), leave::HubAnswer::Revoked).await.left);
    assert_eq!(relay_config(home.path()), None);
}

#[tokio::test]
async fn a_node_key_from_before_sign_in_survives_sign_out_and_a_restart() {
    let key = |home: &Path| std::fs::read(home.join("node.wg.key")).ok();
    let home = tempfile::tempdir().unwrap();
    crate::cli::mesh_node_key::load_or_create_at(home.path()).unwrap();
    let before = key(home.path());
    let port = FakeHub::at(home.path());
    assert_eq!(enroll(home.path(), &port).await, EnrollOutcome::Joined);
    assert_eq!(key(home.path()), before, "the join redeems with the key that was there");
    assert!(sign_out(home.path(), leave::HubAnswer::Revoked).await.left);
    assert_eq!(key(home.path()), before);
    // A restart: the start's leave, then a sign-in that joins again with the same key.
    leave_marked(home.path(), Some("box-a"), true, |_| async { leave::HubAnswer::Revoked }).await;
    assert_eq!(key(home.path()), before);
    assert_eq!(enroll(home.path(), &port).await, EnrollOutcome::Joined);
    assert!(sign_out(home.path(), leave::HubAnswer::Revoked).await.left);
    assert_eq!(key(home.path()), before);

    // A key the sign-in's join made goes with its sign-out.
    let home = tempfile::tempdir().unwrap();
    let port = FakeHub::at(home.path());
    assert_eq!(enroll(home.path(), &port).await, EnrollOutcome::Joined);
    assert!(key(home.path()).is_some());
    assert!(sign_out(home.path(), leave::HubAnswer::Revoked).await.left);
    assert_eq!(key(home.path()), None);
}

#[tokio::test]
async fn a_sign_in_join_finished_later_is_still_left_by_sign_out() {
    let home = tempfile::tempdir().unwrap();
    let port = FakeHub::at(home.path());
    // The earlier sign-in's redeem landed and its probe failed: the pending proposal
    // completes now as what began it (`recovery::completed_record`).
    *port.resumed.lock().unwrap() = Some(MachineCredential {
        credential: "cmm_pending".into(),
        machine_id: "machine_pending".into(),
        hub_origin: HUB.into(),
        user_id: Some("user_me".into()),
        host_fingerprint: Some("box-a".into()),
        joined_by: Some(JOINED_BY_SIGN_IN.into()),
        capabilities: Some(machine_capabilities()),
        ..Default::default()
    });
    assert_eq!(enroll(home.path(), &port).await, EnrollOutcome::AlreadyJoined);
    assert_eq!(port.resumes.load(Ordering::SeqCst), 1);
    assert_eq!(port.mints.load(Ordering::SeqCst), 0);
    let left = sign_out(home.path(), leave::HubAnswer::Revoked).await;
    assert!(left.left, "{left:?}");
}

fn queued_credentials(home: &Path) -> Vec<String> {
    let mut credentials: Vec<String> = to_revoke::queued(home)
        .unwrap()
        .into_iter()
        .filter_map(|(_, row)| row.credential)
        .collect();
    credentials.sort();
    credentials
}

/// Every revoke at the next start answered `Revoked`; the credentials asked, sorted.
async fn start_with_the_hub_up(home: &Path) -> Vec<String> {
    let asked = Mutex::new(Vec::new());
    leave_marked(home, Some("box-a"), true, |record: MachineCredential| {
        asked.lock().unwrap().push(record.credential);
        async { leave::HubAnswer::Revoked }
    })
    .await;
    let mut asked = asked.into_inner().unwrap();
    asked.sort();
    asked
}

#[tokio::test]
async fn two_failed_revokes_in_a_row_are_both_kept_and_both_revoked() {
    let home = tempfile::tempdir().unwrap();
    let down = || leave::HubAnswer::Unavailable("down".into());
    joined(home.path(), signed_in);
    assert!(sign_out(home.path(), down()).await.left);
    joined(home.path(), |r| {
        signed_in(r);
        r.credential = "cmm_second".into();
        r.machine_id = "machine_second".into();
    });
    assert!(sign_out(home.path(), down()).await.left);
    // The second sign-out's row never replaces the first's.
    assert_eq!(queued_credentials(home.path()), ["cmm_old", "cmm_second"]);
    assert_eq!(start_with_the_hub_up(home.path()).await, ["cmm_old", "cmm_second"]);
    assert!(!to_revoke::any_queued(home.path()));
    assert!(!home.path().join(LEAVE_FILE).exists());
}

#[tokio::test]
async fn two_set_aside_proposals_whose_revokes_fail_are_both_kept_and_revoked_later() {
    let home = tempfile::tempdir().unwrap();
    for credential in ["cmm_first", "cmm_second"] {
        pending_join_as(home.path(), credential, Some(JOINED_BY_SIGN_IN), "box-a");
        let left = sign_out(home.path(), leave::HubAnswer::Unavailable("down".into())).await;
        assert_eq!(left.kept, Some("notJoined"));
        assert!(!home.path().join("machine-join.pending.json").exists());
    }
    assert_eq!(queued_credentials(home.path()), ["cmm_first", "cmm_second"]);
    assert_eq!(start_with_the_hub_up(home.path()).await, ["cmm_first", "cmm_second"]);
    assert!(!to_revoke::any_queued(home.path()));
}

/// A sign-in join whose sign-out sent its revoke, which the hub committed, and stopped before
/// the answer (the leave's future is dropped there): nothing here was removed yet.
async fn stopped_after_the_revoke(home: &Path) {
    joined(home, signed_in);
    configure_mesh_relay_at(&home.join("config.json"), HUB).unwrap();
    mark_leave(home, Some("user_me")).unwrap();
    let leave =
        leave_marked(home, Some("box-a"), false, |_| std::future::pending::<leave::HubAnswer>());
    // timeout: short-gate: a test's bound on a leave that must stop at a revoke that never answers.
    let stop = tokio::time::timeout(std::time::Duration::from_millis(300), leave).await;
    assert!(stop.is_err(), "the leave stops at its revoke");
    assert!(!load_at(home).unwrap().unwrap().revoked);
}

#[tokio::test]
async fn a_sign_out_stopped_after_the_hub_took_its_revoke_still_lets_a_sign_in_enroll() {
    // Finished at the next start: the hub's "already revoked" is this sign-out's own.
    let home = tempfile::tempdir().unwrap();
    stopped_after_the_revoke(home.path()).await;
    let at_start = leave_marked(home.path(), Some("box-a"), true, |_| async {
        leave::HubAnswer::AlreadyGone { revoked: true }
    })
    .await;
    assert!(at_start.left, "{at_start:?}");
    assert_eq!(at_start.hub, Some("revoked"));
    assert!(!to_revoke::revoked_on(home.path(), HUB, Some("box-a")));
    assert!(load_at(home.path()).unwrap().is_none());
    let port = FakeHub::at(home.path());
    assert_eq!(enroll(home.path(), &port).await, EnrollOutcome::Joined);

    // Signed in before any start: the hub says the record is revoked, by that sign-out.
    let home = tempfile::tempdir().unwrap();
    stopped_after_the_revoke(home.path()).await;
    let port = FakeHub::at(home.path());
    *port.self_check.lock().unwrap() = Some(SelfCheck::Revoked);
    assert_eq!(enroll(home.path(), &port).await, EnrollOutcome::Joined);
    assert_eq!(load_at(home.path()).unwrap().unwrap().credential, "cmm_new");

    // Its relay's 401 marked the record revoked here first: the same.
    let home = tempfile::tempdir().unwrap();
    stopped_after_the_revoke(home.path()).await;
    let mut record = load_at(home.path()).unwrap().unwrap();
    record.revoked = true;
    save_at(home.path(), &record).unwrap();
    let port = FakeHub::at(home.path());
    assert_eq!(enroll(home.path(), &port).await, EnrollOutcome::Joined);

    // The revoke never reached the hub: the sign-in keeps the join, and a later revoke of it
    // by someone else is theirs again.
    let home = tempfile::tempdir().unwrap();
    stopped_after_the_revoke(home.path()).await;
    let port = FakeHub::at(home.path());
    assert_eq!(enroll(home.path(), &port).await, EnrollOutcome::AlreadyJoined);
    let gone = sign_out(home.path(), leave::HubAnswer::AlreadyGone { revoked: true }).await;
    assert!(gone.left);
    assert_eq!(enroll(home.path(), &port).await, EnrollOutcome::Revoked);
}

#[tokio::test]
async fn a_sign_out_says_the_relay_went_only_when_it_removed_the_joins() {
    // The person's relay beside a sign-in join stays in config.json, so it keeps running.
    let home = tempfile::tempdir().unwrap();
    let own = json!({"url": "https://own.example", "tokenCommand": ["mint"]});
    std::fs::write(home.path().join("config.json"), json!({"meshRelay": own}).to_string()).unwrap();
    joined(home.path(), signed_in);
    let left = sign_out(home.path(), leave::HubAnswer::Revoked).await;
    assert!(left.left && !left.relay_removed, "{left:?}");
    assert!(relay_may_start(&left), "a start after it runs the person's relay");
    assert_eq!(relay_config(home.path()), Some(own));
    // The join's own relay goes, and stops.
    let home = tempfile::tempdir().unwrap();
    configure_mesh_relay_at(&home.path().join("config.json"), HUB).unwrap();
    joined(home.path(), signed_in);
    let left = sign_out(home.path(), leave::HubAnswer::Revoked).await;
    assert!(left.left && left.relay_removed, "{left:?}");
    assert!(!relay_may_start(&left));
}

/// What another account, or no account, signing in and out did to the join in `home`: the
/// join's credential stays, nothing is revoked and nothing minted.
fn assert_untouched(home: &Path, port: &FakeHub) {
    assert_eq!(load_at(home).unwrap().unwrap().credential, "cmm_old");
    assert!(port.own_revokes.lock().unwrap().is_empty());
    assert!(port.revoked.lock().unwrap().is_empty());
    assert_eq!(port.mints.load(Ordering::SeqCst), 0);
    assert!(!to_revoke::any_queued(home));
}

#[tokio::test]
async fn another_accounts_sign_in_never_gets_already_joined() {
    // A join recorded under no account (an older join, or a hub that named none): not this
    // account's, so neither AlreadyJoined nor a switch's leave.
    let home = tempfile::tempdir().unwrap();
    joined(home.path(), |r| {
        signed_in(r);
        r.user_id = None;
    });
    configure_mesh_relay_at(&home.path().join("config.json"), HUB).unwrap();
    let port = FakeHub::at(home.path());
    assert_eq!(enroll(home.path(), &port).await, EnrollOutcome::OwnerUnknown);
    assert_untouched(home.path(), &port);
    assert!(relay_config(home.path()).is_some());
    // A join line's under another account: that account's, left alone.
    let home = tempfile::tempdir().unwrap();
    joined(home.path(), |r| r.user_id = Some("user_b".into()));
    let port = FakeHub::at(home.path());
    assert_eq!(enroll(home.path(), &port).await, EnrollOutcome::OtherUser);
    assert_untouched(home.path(), &port);
    // An enroll naming no account: nothing is read as its, and nothing is made.
    for edit in [signed_in as fn(&mut MachineCredential), |r| r.user_id = None] {
        let home = tempfile::tempdir().unwrap();
        joined(home.path(), edit);
        let port = FakeHub::at(home.path());
        let outcome = enroll_at(home.path(), HUB, "box", None, Some("box-a"), &port).await;
        assert_eq!(outcome, EnrollOutcome::OwnerUnknown);
        assert_untouched(home.path(), &port);
    }
    let home = tempfile::tempdir().unwrap();
    let port = FakeHub::at(home.path());
    let outcome = enroll_at(home.path(), HUB, "box", None, Some("box-a"), &port).await;
    assert_eq!(outcome, EnrollOutcome::OwnerUnknown);
    assert_eq!(port.mints.load(Ordering::SeqCst), 0);
    assert!(load_at(home.path()).unwrap().is_none());
}

#[tokio::test]
async fn another_accounts_sign_out_leaves_the_join() {
    // user_me's sign-in joined, and a proposal of user_me's is pending.
    let home = tempfile::tempdir().unwrap();
    joined(home.path(), signed_in);
    pending_join(home.path(), Some(JOINED_BY_SIGN_IN), "box-a");
    configure_mesh_relay_at(&home.path().join("config.json"), HUB).unwrap();
    let port = FakeHub::at(home.path());
    for account in [Some("user_b"), None] {
        mark_leave(home.path(), account).unwrap();
        let left =
            leave_marked(home.path(), Some("box-a"), false, |record| port.revoke_own(record)).await;
        let why = if account.is_some() { "otherUser" } else { "ownerUnknown" };
        assert_eq!(left.kept, Some(why));
        assert!(relay_may_start(&left));
        assert_untouched(home.path(), &port);
        assert!(relay_config(home.path()).is_some());
        assert!(home.path().join("machine-join.pending.json").exists(), "user_me's stays");
        assert!(!home.path().join(LEAVE_FILE).exists());
    }
    // The account that joined it signs out: it goes.
    let left = sign_out(home.path(), leave::HubAnswer::Revoked).await;
    assert!(left.left);
    assert!(load_at(home.path()).unwrap().is_none());
    assert!(!home.path().join("machine-join.pending.json").exists());
}

#[tokio::test]
async fn an_ownerless_record_is_never_revoked_by_a_sign_out() {
    let home = tempfile::tempdir().unwrap();
    joined(home.path(), |r| {
        signed_in(r);
        r.user_id = None;
    });
    configure_mesh_relay_at(&home.path().join("config.json"), HUB).unwrap();
    let port = FakeHub::at(home.path());
    let left = sign_out(home.path(), leave::HubAnswer::Revoked).await;
    assert_eq!(left.kept, Some("ownerUnknown"));
    assert_untouched(home.path(), &port);
    assert!(relay_config(home.path()).is_some());
    // Nor at the next start, nor once another account signed in and out.
    assert!(finish_marked_at_start(home.path()).await.is_none_or(|left| !left.left));
    assert_eq!(enroll(home.path(), &port).await, EnrollOutcome::OwnerUnknown);
    assert_untouched(home.path(), &port);
}

async fn finish_marked_at_start(home: &Path) -> Option<LeaveOutcome> {
    if std::fs::symlink_metadata(home.join(LEAVE_FILE)).is_err() {
        return None;
    }
    Some(leave_marked(home, Some("box-a"), true, |_| async { leave::HubAnswer::Revoked }).await)
}

#[test]
fn a_leave_mark_keeps_every_account_it_named() {
    let home = tempfile::tempdir().unwrap();
    mark_leave(home.path(), Some("user_me")).unwrap();
    mark_leave(home.path(), None).unwrap();
    assert_eq!(leave_accounts(home.path()), ["user_me"]);
    mark_leave(home.path(), Some("user_b")).unwrap();
    mark_leave(home.path(), Some("user_me")).unwrap();
    assert_eq!(leave_accounts(home.path()), ["user_me", "user_b"]);
    // The cleanup's mark keeps them.
    mark_leave_removing(home.path()).unwrap();
    assert!(leave_removing(home.path()));
    assert_eq!(leave_accounts(home.path()), ["user_me", "user_b"]);
}

/// The app's intent for `account`, as `acpmux machine leave-intent` writes it.
fn intent(home: &Path, account: &str) {
    mark_leave(home, Some(account)).unwrap();
}

/// #38319 review F2 (#38440 F3): the app signs out, its intent writer starts and waits for
/// the join lock, the same account signs back in and enrolls, and only then does the writer
/// get the lock. Its intent is from before that sign-in: not recorded, and the next start
/// leaves the newer join. A sign-out after that sign-in is recorded and leaves.
#[tokio::test]
async fn a_leave_intent_written_late_never_leaves_the_newer_join() {
    let home = tempfile::tempdir().unwrap();
    let port = FakeHub::at(home.path());
    let signed_out_at = now_ms().saturating_sub(1_000);
    assert_eq!(enroll(home.path(), &port).await, EnrollOutcome::Joined);
    let joined = load_at(home.path()).unwrap().expect("joined");
    let late = record_leave_intent_at(home.path(), "user_me", Some(signed_out_at)).await;
    assert!(!late.unwrap(), "a stale intent is not recorded");
    let at_start = finish_marked_at_start(home.path()).await;
    assert!(at_start.as_ref().is_none_or(|left| !left.left), "{at_start:?}");
    let kept = load_at(home.path()).unwrap().expect("the newer join stays");
    assert_eq!(kept.credential, joined.credential);
    assert!(!kept.revoked);
    // Another account's late intent is still recorded: this sign-in was not theirs.
    assert!(record_leave_intent_at(home.path(), "user_b", Some(signed_out_at)).await.unwrap());
    remove_mark(home.path(), LEAVE_FILE);
    // A sign-out after this sign-in is recorded, and the start leaves the join.
    assert!(record_leave_intent_at(home.path(), "user_me", None).await.unwrap());
    let left = finish_marked_at_start(home.path()).await.expect("a leave is marked");
    assert!(left.left, "{left:?}");
    assert!(load_at(home.path()).unwrap().is_none());
}

/// A leave asked of the daemon by `account` (None: a launch signed out).
async fn asked(home: &Path, account: Option<&str>, port: &FakeHub) -> LeaveOutcome {
    leave_asked(home, Some("box-a"), account, |record| port.revoke_own(record)).await
}

#[tokio::test]
async fn a_sign_out_the_daemon_never_got_is_finished_by_a_launch_that_names_no_account() {
    // user_me's sign-in joined; the app wrote the intent, then its leave never reached
    // acpmux and the app quit.
    let home = tempfile::tempdir().unwrap();
    joined(home.path(), signed_in);
    configure_mesh_relay_at(&home.path().join("config.json"), HUB).unwrap();
    intent(home.path(), "user_me");
    // The next launch, signed out, knows no account: the intent does.
    let port = FakeHub::at(home.path());
    let left = asked(home.path(), None, &port).await;
    assert!(left.left, "{left:?}");
    assert_eq!(*port.own_revokes.lock().unwrap(), vec!["cmm_old".to_owned()]);
    assert!(load_at(home.path()).unwrap().is_none());
    assert!(relay_config(home.path()).is_none());
    assert!(!home.path().join(LEAVE_FILE).exists());
    // Or the daemon's next start finishes it first, with no request at all.
    let home = tempfile::tempdir().unwrap();
    joined(home.path(), signed_in);
    intent(home.path(), "user_me");
    let port = FakeHub::at(home.path());
    let at_start =
        leave_marked(home.path(), Some("box-a"), true, |record| port.revoke_own(record)).await;
    assert!(at_start.left, "{at_start:?}");
    assert!(load_at(home.path()).unwrap().is_none());
    // A leave naming no account, with no intent: the join stays (its owner is not known).
    let home = tempfile::tempdir().unwrap();
    joined(home.path(), signed_in);
    let port = FakeHub::at(home.path());
    assert_eq!(asked(home.path(), None, &port).await.kept, Some("ownerUnknown"));
    assert_untouched(home.path(), &port);
}

#[tokio::test]
async fn an_intent_for_one_account_survives_another_accounts_sign_in() {
    // A's sign-in joined, A's sign-out reached only the intent, then B signs in: A's leave
    // is finished as A's, then B enrolls.
    let home = tempfile::tempdir().unwrap();
    joined(home.path(), |r| {
        signed_in(r);
        r.user_id = Some("user_a".into());
    });
    intent(home.path(), "user_a");
    let port = FakeHub::at(home.path());
    *port.own_answer.lock().unwrap() = Some(leave::HubAnswer::Unavailable("down".into()));
    assert_eq!(enroll(home.path(), &port).await, EnrollOutcome::Joined);
    // A's leave asked once, then its queued revoke once more before B's enroll.
    assert_eq!(*port.own_revokes.lock().unwrap(), vec!["cmm_old".to_owned(); 2]);
    assert_eq!(load_at(home.path()).unwrap().unwrap().user_id.as_deref(), Some("user_me"));
    // A's hub did not answer: A's credential stays queued, revoked at the next start; B's
    // join is untouched.
    assert!(to_revoke::any_queued(home.path()));
    *port.own_answer.lock().unwrap() = None;
    let at_start =
        leave_marked(home.path(), Some("box-a"), true, |record| port.revoke_own(record)).await;
    assert!(relay_may_start(&at_start));
    assert_eq!(*port.own_revokes.lock().unwrap(), vec!["cmm_old".to_owned(); 3]);
    assert_eq!(load_at(home.path()).unwrap().unwrap().credential, "cmm_new");
    assert!(!to_revoke::any_queued(home.path()));
    assert!(!home.path().join(LEAVE_FILE).exists());

    // B's own join here, and an intent of A's: B's sign-in keeps B's join and finishes A's.
    let home = tempfile::tempdir().unwrap();
    joined(home.path(), signed_in);
    intent(home.path(), "user_a");
    let port = FakeHub::at(home.path());
    *port.self_check.lock().unwrap() = Some(SelfCheck::Live);
    assert_eq!(enroll(home.path(), &port).await, EnrollOutcome::AlreadyJoined);
    assert!(port.own_revokes.lock().unwrap().is_empty());
    assert_eq!(load_at(home.path()).unwrap().unwrap().credential, "cmm_old");
    assert!(!home.path().join(LEAVE_FILE).exists());
    // A's intent, then B's sign-in did not reach acpmux and B signs out too: both are named,
    // and only A's join (the one here) goes.
    let home = tempfile::tempdir().unwrap();
    joined(home.path(), |r| {
        signed_in(r);
        r.user_id = Some("user_a".into());
    });
    intent(home.path(), "user_a");
    intent(home.path(), "user_b");
    let port = FakeHub::at(home.path());
    assert!(asked(home.path(), None, &port).await.left);
    assert!(load_at(home.path()).unwrap().is_none());
}

#[test]
fn a_dev_build_tag_names_the_machine_apart() {
    let base = crate::pairing::machine_name();
    assert_eq!(enroll_name(None), base);
    assert_eq!(enroll_name(Some("  ")), base);
    assert_eq!(enroll_name(Some("Sign In!")), format!("{base}-signin"));
    assert!(enroll_name(Some(&"x".repeat(200))).len() <= 63);
}
