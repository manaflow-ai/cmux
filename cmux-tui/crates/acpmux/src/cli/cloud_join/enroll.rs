//! Signing in enrolls this machine (Leo: "Signing in enrolls the machine. Today a second Mac
//! signed into the same account does nothing until you run 'cmux pair CODE' or paste the curl
//! join line."). With the person's access token, acpmux mints its own single-use join token
//! (`POST /v1/machines/join-tokens`) and redeems it here, the same redeem a pasted join line
//! makes (`recovery.rs`). The pair code and the join line stay for machines with no sign-in.
//!
//! - Already joined to this hub (and not revoked there): nothing is minted.
//! - Revoked: never enrolled again on its own; the person rejoins (`host join --replace`).
//! - Joined by another person, or to another hub: that join is left alone.
//! - A home copied from another box: this box enrolls as itself (`settle_clone_at` first gives
//!   it its own node key, so the original box's hub row is never touched).
//! - A sign-out here whose hub did not revoke the machine left its row: the next sign-in revokes
//!   that row by its id with the person's token, then enrolls. Never matched on the node key or the
//!   host name alone, which a copied home or a twin machine shares.
//!
//! The record says `joined_by: "sign-in"`, so signing out removes only a join signing in made
//! ([`leave_if_auto`]); a pair-code or join-line machine stays joined.
//!
//! Neither the access token nor the join token is put in argv, the environment, a file or a
//! log: both stay in memory (zeroized when dropped) and go only into their own hub request.
use super::*;
use std::future::Future;
use std::path::Path;
use zeroize::Zeroizing;

/// `joined_by` of a join signing in made.
pub(crate) const JOINED_BY_SIGN_IN: &str = "sign-in";
/// The minted token's life: the shortest the hub takes; it is redeemed at once.
const MINT_TTL_SECS: u64 = 60;
/// How long an enroll waits for another join or leave on this machine to finish.
const LOCK_WAIT: std::time::Duration = std::time::Duration::from_secs(30);

/// What an enroll did.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) enum EnrollOutcome {
    /// Minted and redeemed: this machine joined now.
    Joined,
    /// Already joined to this hub: nothing minted.
    AlreadyJoined,
    /// Revoked: left so until the person rejoins it.
    Revoked,
    /// Joined by another person: left alone.
    OtherUser,
    /// Joined to another hub: left alone.
    OtherHub,
    /// The hub did not answer, refused, or another join held this machine: nothing changed.
    Unavailable,
}

/// What signing in asks for. The access token is passed beside it, never in it.
#[derive(Debug, Default, Clone)]
pub(crate) struct EnrollRequest {
    /// The hub origin; None is the join's default (`CMUX_PLATFORM_ORIGIN`, else production).
    pub hub: Option<String>,
    /// The signed-in person's id, when the caller knows it: a join recorded under another
    /// person is left alone.
    pub user_id: Option<String>,
    /// A DEV build's tag, added to the machine's name so its join is told apart.
    pub build_tag: Option<String>,
}

/// What a sign-out's leave did.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct LeaveOutcome {
    pub left: bool,
    /// Why nothing was left: `notJoined`, `notBySignIn` or `busy`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub kept: Option<&'static str>,
    /// What the hub said to the revoke, when one was asked.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub hub: Option<&'static str>,
}

/// What the hub says to a joined record's own credential.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum SelfCheck {
    Live,
    Revoked,
    /// The hub does not know it: dead, though never revoked.
    Unknown,
    Unavailable,
}

/// The hub calls an enroll makes, apart so tests drive them with a fake hub.
pub(super) trait EnrollHub {
    fn check_self(&self, record: &MachineCredential) -> impl Future<Output = SelfCheck> + Send;
    /// The team's credential rows as `(machineId, wgPublicKey, revoked)`.
    fn credentials(&self) -> impl Future<Output = Result<Vec<(String, String, bool)>>> + Send;
    fn revoke(&self, machine_id: &str) -> impl Future<Output = Result<()>> + Send;
    fn mint(&self, label: &str) -> impl Future<Output = Result<Zeroizing<String>>> + Send;
    /// Redeems `token` as this machine (`recovery::join`), writing the record.
    fn redeem(
        &self,
        name: &str,
        token: Zeroizing<String>,
        replace: bool,
    ) -> impl Future<Output = Result<()>> + Send;
}

/// The machine's name: its host name, with a DEV build's tag after it.
fn enroll_name(build_tag: Option<&str>) -> String {
    let base = crate::pairing::machine_name();
    let tag: String = build_tag
        .unwrap_or_default()
        .chars()
        .map(|c| c.to_ascii_lowercase())
        .filter(|c| c.is_ascii_alphanumeric() || *c == '-')
        .collect();
    let tag = tag.trim_matches('-');
    // The hub takes a label of at most 63 characters (`JoinTokenMint.label`); the name is ASCII.
    let mut name = if tag.is_empty() { base } else { format!("{base}-{tag}") };
    name.truncate(63);
    name.trim_end_matches('-').to_owned()
}

/// The hub row a sign-out left behind when the hub did not revoke it: the next sign-in on this box
/// revokes exactly that row. Never a match on the node key or the host name alone, which a copied
/// home or a twin machine shares.
const STALE_FILE: &str = "machine-join.stale.json";

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct StaleRow {
    machine_id: String,
    hub_origin: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    host_fingerprint: Option<String>,
}

fn record_stale(home: &Path, record: &MachineCredential) -> Result<()> {
    let row = StaleRow {
        machine_id: record.machine_id.clone(),
        hub_origin: record.hub_origin.clone(),
        host_fingerprint: record.host_fingerprint.clone(),
    };
    recovery::write_durable(&home.join(STALE_FILE), &serde_json::to_vec(&row)?, true)
}

/// The stale row this box's own sign-out left on `hub`, if any (a copied home's is not this box's).
fn stale_row(home: &Path, hub: &str, current: Option<&str>) -> Option<StaleRow> {
    let file = crate::config::private_state_file(&home.join(STALE_FILE)).ok()?;
    let row: StaleRow = serde_json::from_reader(file).ok()?;
    (row.host_fingerprint.as_deref() == current
        && origin(Some(row.hub_origin.clone())).ok().as_deref() == Some(hub))
    .then_some(row)
}

/// Takes the join lock in `home`, waiting up to [`LOCK_WAIT`] for a join or leave in progress.
async fn wait_for_lock(home: &Path) -> Option<HeldLock> {
    let deadline = tokio::time::Instant::now() + LOCK_WAIT;
    loop {
        if let Ok(lock) = crate::config::private_state_dir(home).and_then(|()| join_lock_at(home)) {
            return Some(lock);
        }
        if tokio::time::Instant::now() >= deadline {
            return None;
        }
        tokio::time::sleep(std::time::Duration::from_millis(200)).await;
    }
}

/// Enrolls the box whose fingerprint is `current` with its acpmux home at `home`, through `port`.
/// Holds the join lock throughout, so two enrolls at once mint once: the second finds the first's
/// join.
pub(super) async fn enroll_at(
    home: &Path,
    hub: &str,
    name: &str,
    user_id: Option<&str>,
    current: Option<&str>,
    port: &impl EnrollHub,
) -> EnrollOutcome {
    let Some(_lock) = wait_for_lock(home).await else { return EnrollOutcome::Unavailable };
    // A home copied from another box: marked, and this box given its own node key, before the
    // key is compared with the hub's rows below.
    if settle_clone_at(home, current).is_err() {
        return EnrollOutcome::Unavailable;
    }
    let Ok(record) = load_at(home) else { return EnrollOutcome::Unavailable };
    let mut replace = false;
    if let Some(record) = record.filter(|record| !copied_here(home, record, current)) {
        if record.revoked {
            return EnrollOutcome::Revoked;
        }
        if origin(Some(record.hub_origin.clone())).ok().as_deref() != Some(hub) {
            return EnrollOutcome::OtherHub;
        }
        if let (Some(mine), Some(theirs)) = (user_id, record.user_id.as_deref())
            && mine != theirs
        {
            return EnrollOutcome::OtherUser;
        }
        match port.check_self(&record).await {
            // Unreachable says nothing against the join here: it stays as it is.
            SelfCheck::Live | SelfCheck::Unavailable => return EnrollOutcome::AlreadyJoined,
            SelfCheck::Revoked => {
                let _ = save_at(home, &MachineCredential { revoked: true, ..record });
                return EnrollOutcome::Revoked;
            }
            // Dead at the hub, never revoked by anyone: this box enrolls again in its place.
            SelfCheck::Unknown => replace = true,
        }
    }
    // The row this box's last sign-out could not revoke: revoke it now with the person's token,
    // so the machine never shows twice. A failed list or revoke does not stop the enroll.
    if let Some(stale) = stale_row(home, hub, current)
        && let Ok(rows) = port.credentials().await
    {
        let live = rows.iter().any(|(id, _, revoked)| *id == stale.machine_id && !revoked);
        let gone = !live || port.revoke(&stale.machine_id).await.is_ok();
        if gone {
            let _ = std::fs::remove_file(home.join(STALE_FILE));
        } else {
            tracing::warn!(machine = %stale.machine_id, "sign-in enroll: the stale row stayed");
        }
    }
    let token = match port.mint(name).await {
        Ok(token) => token,
        Err(e) => {
            tracing::warn!("sign-in enroll: the mint failed: {e:#}");
            return EnrollOutcome::Unavailable;
        }
    };
    match port.redeem(name, token, replace).await {
        Ok(()) => EnrollOutcome::Joined,
        Err(e) => {
            tracing::warn!("sign-in enroll: the redeem failed: {e:#}");
            EnrollOutcome::Unavailable
        }
    }
}

/// The hub as the signed-in person (`access`), and as this machine for its own credential.
struct Platform {
    hub: String,
    access: Zeroizing<String>,
}

impl Platform {
    fn person(&self) -> Result<cmux_cloud_client::Client> {
        hub_client(&self.hub, Some(&self.access))
    }
}

/// A refusal's status and code only: its message may repeat what was sent.
async fn refused(error: cmux_cloud_client::Error<cmux_cloud_client::ByteStream>) -> anyhow::Error {
    let error = cmux_cloud_client::ApiError::from_api(error).await;
    anyhow!("the hub refused: {:?} {}", error.status, error.code.unwrap_or_default())
}

impl EnrollHub for Platform {
    async fn check_self(&self, record: &MachineCredential) -> SelfCheck {
        let Ok(client) = hub_client(&self.hub, Some(&record.credential)) else {
            return SelfCheck::Unavailable;
        };
        match client.machine_redeem_self().await {
            Ok(_) => SelfCheck::Live,
            Err(error) => {
                let error = cmux_cloud_client::ApiError::from_api(error).await;
                match (error.status, error.code.as_deref()) {
                    (Some(401), Some("machine.revoked")) => SelfCheck::Revoked,
                    (Some(401), Some("machine.unknown")) => SelfCheck::Unknown,
                    _ => SelfCheck::Unavailable,
                }
            }
        }
    }

    async fn credentials(&self) -> Result<Vec<(String, String, bool)>> {
        let body = match self.person()?.machine_join_list().await {
            Ok(body) => serde_json::to_value(body.into_inner())?,
            Err(error) => return Err(refused(error).await),
        };
        Ok(body
            .get("machines")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(|row| {
                Some((
                    row.get("machineId")?.as_str()?.to_owned(),
                    row.get("wgPublicKey")?.as_str()?.to_owned(),
                    row.get("revoked").and_then(Value::as_bool).unwrap_or(false),
                ))
            })
            .collect())
    }

    async fn revoke(&self, machine_id: &str) -> Result<()> {
        let id = machine_id.parse().map_err(|_| anyhow!("malformed machine id"))?;
        match self.person()?.machine_join_revoke(&id).await {
            Ok(_) => Ok(()),
            Err(error) => Err(refused(error).await),
        }
    }

    async fn mint(&self, label: &str) -> Result<Zeroizing<String>> {
        let body: cmux_cloud_client::types::JoinTokenMint =
            serde_json::from_value(json!({"label": label, "ttlSeconds": MINT_TTL_SECS}))?;
        let minted = match self.person()?.machine_join_mint(&body).await {
            Ok(body) => serde_json::to_value(body.into_inner())?,
            Err(error) => return Err(refused(error).await),
        };
        let token = minted
            .get("token")
            .and_then(Value::as_str)
            .ok_or_else(|| anyhow!("the hub minted no token"))?;
        Ok(Zeroizing::new(parse_token_text(token).map_err(|_| anyhow!("minted token malformed"))?))
    }

    async fn redeem(&self, name: &str, token: Zeroizing<String>, replace: bool) -> Result<()> {
        // Finishing a pasted join line left half done: that join stays the person's, not sign-in's.
        let joined_by =
            recovery::pending_origin().ok().flatten().is_none().then_some(JOINED_BY_SIGN_IN);
        recovery::join(
            Some(self.hub.clone()),
            Some(name.to_owned()),
            replace,
            Report::Quiet,
            Some(token.as_str().to_owned()),
            joined_by,
        )
        .await
    }
}

/// Enrolls this machine for the person whose access token is `access` (the daemon's
/// `_acpmux/machine_enroll` and `acpmux host enroll-self`).
pub(crate) async fn enroll_self(
    request: EnrollRequest,
    access: Zeroizing<String>,
) -> EnrollOutcome {
    let Ok(hub) = origin(request.hub.clone()) else { return EnrollOutcome::Unavailable };
    if access.trim().is_empty() {
        return EnrollOutcome::Unavailable;
    }
    let name = enroll_name(request.build_tag.as_deref());
    let user_id = request.user_id.as_deref().and_then(safe_id);
    let port = Platform { hub: hub.clone(), access };
    let current = host_fingerprint::current();
    enroll_at(&state_dir(), &hub, &name, user_id.as_deref(), current.as_deref(), &port).await
}

/// Signing out: leaves the hub only when signing in joined this machine (`joined_by: "sign-in"`).
/// A pair-code or join-line machine stays joined, and a revoked one stays revoked. The hub is asked
/// to revoke the credential with the credential itself; the join here goes either way, and a row the
/// hub did not revoke is recorded so the next sign-in revokes it.
pub(crate) async fn leave_if_auto() -> LeaveOutcome {
    let home = state_dir();
    let kept = |why| LeaveOutcome { left: false, kept: Some(why), hub: None };
    let Some(_lock) = wait_for_lock(&home).await else { return kept("busy") };
    let Ok(Some(record)) = load_at(&home) else { return kept("notJoined") };
    if record.joined_by.as_deref() != Some(JOINED_BY_SIGN_IN) {
        return kept("notBySignIn");
    }
    // A revoked machine stays so: its record keeps the next sign-in from enrolling it again.
    if record.revoked {
        return kept("revoked");
    }
    let copy = copied_here(&home, &record, host_fingerprint::current().as_deref());
    let answer = if copy { None } else { Some(leave::revoke_at_hub(&record).await) };
    // Not revoked at the hub: the next sign-in here revokes that row by its id.
    if answer.as_ref().is_some_and(|answer| !answer.revoked())
        && record_stale(&home, &record).is_err()
    {
        return kept("busy");
    }
    if leave::remove_local(&home).is_err() {
        return kept("busy");
    }
    LeaveOutcome { left: true, kept: None, hub: answer.map(|answer| answer.label()) }
}

#[cfg(all(test, unix))]
mod tests {
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
        async fn redeem(&self, name: &str, token: Zeroizing<String>, replace: bool) -> Result<()> {
            assert_eq!(token.as_str(), "cmj_fake");
            if let Some(wait) = self.redeem_wait {
                tokio::time::sleep(wait).await;
            }
            self.redeems.lock().unwrap().push((name.to_owned(), replace));
            let key = crate::cli::mesh_node_key::load_or_create_at(&self.home)?.public_key_b64();
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
                    user_id: Some("user_me".into()),
                    host_fingerprint: Some("box-a".into()),
                    joined_by: Some(JOINED_BY_SIGN_IN.into()),
                    ..Default::default()
                },
            )
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
            ..Default::default()
        };
        edit(&mut record);
        save_at(home, &record).unwrap();
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
        let key =
            crate::cli::mesh_node_key::load_or_create_at(home.path()).unwrap().public_key_b64();
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
        let port = FakeHub {
            rows: Mutex::new(port.rows.lock().unwrap().clone()),
            ..FakeHub::at(home.path())
        };
        let lost = MachineCredential {
            machine_id: "machine_lost".into(),
            hub_origin: HUB.into(),
            host_fingerprint: Some("box-a".into()),
            ..Default::default()
        };
        record_stale(home.path(), &lost).unwrap();
        assert_eq!(enroll(home.path(), &port).await, EnrollOutcome::Joined);
        assert_eq!(*port.revoked.lock().unwrap(), vec!["machine_lost".to_owned()]);
        assert!(!home.path().join(STALE_FILE).exists());
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
        record_stale(home.path(), &other).unwrap();
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
    fn a_dev_build_tag_names_the_machine_apart() {
        let base = crate::pairing::machine_name();
        assert_eq!(enroll_name(None), base);
        assert_eq!(enroll_name(Some("  ")), base);
        assert_eq!(enroll_name(Some("Sign In!")), format!("{base}-signin"));
        assert!(enroll_name(Some(&"x".repeat(200))).len() <= 63);
    }
}
