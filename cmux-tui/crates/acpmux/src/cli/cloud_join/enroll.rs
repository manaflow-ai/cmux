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
//! ([`leave_if_auto`]); a pair-code or join-line machine stays joined. A sign-in join left half
//! done keeps that provenance in its pending proposal, so whatever finishes it, it stays one.
//!
//! - Signing out leaves durably: the leave is marked before anything else, and a leave the
//!   daemon did not finish (no answer, the join lock held, a failed write, a stop) is finished
//!   at its next start, before its mesh relay starts. A sign-in clears the mark. A leave whose
//!   local cleanup stopped part way says so in its mark, so it is finished, never read as a
//!   revoke at the hub.
//! - A sign-in's join left pending (the hub took its redeem, its answer or probe never came) goes
//!   with a sign-out too: the proposal is set aside where no join resumes it (a later sign-in by
//!   another person would otherwise finish it as this one's), and its credential is revoked at
//!   the hub with the credential itself. Until the hub says so, each start asks again.
//! - A revoke the hub did not answer is asked again with the machine's own credential, kept
//!   beside the stale row, at each start and each sign-in until the hub says it is revoked,
//!   whoever signs in meanwhile.
//! - Another person signing in on a machine the last person's sign-in joined finishes that
//!   person's leave first (an account switch whose sign-out acpmux never got), then enrolls.
//! - A machine someone revoked at the hub stays revoked here when its sign-out finds it so: a
//!   mark keeps the next sign-in from enrolling it again, until the person joins it themselves.
//! - Already joined: a join left part way (a redeem the hub took, a relay config never
//!   written) is finished, with nothing minted.
//! - Every redeem says what this acpmux can do (`capabilities`, `vault.proxy.v1` when it runs
//!   the vault's egress proxy, else an empty list). A join from before the hub took the list
//!   states it with its own credential (`self_capabilities.rs`), never by a rotate: a rotate the
//!   hub committed whose answer was lost would leave this machine with a retired credential.
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
    /// A relay the person set up holds config.json (a `tokenCommand`, a credential of its own,
    /// another hub's): no sign-in join replaces it, so none is made.
    OwnRelay,
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
    /// Why nothing was left: `notJoined`, `notBySignIn`, `revoked`, `signedIn` (a sign-in since
    /// replaced the sign-out) or `busy` (not finished: the next daemon start finishes it).
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
    /// Finishes a join whose redeem the hub already took (a pending proposal), with no token.
    fn resume(&self) -> impl Future<Output = Result<()>> + Send;
    /// Writes the joined `meshRelay` into config.json when it is missing.
    fn repair_relay(&self) -> Result<()>;
    /// Revokes `record`'s credential with the credential itself (a leave's revoke).
    fn revoke_own(
        &self,
        record: MachineCredential,
    ) -> impl Future<Output = leave::HubAnswer> + Send;
    /// Starts, in the background, a joined record with no list stating this acpmux's
    /// capabilities with its own credential (`self_capabilities.rs`). It saves only after the
    /// enroll let go of the join lock.
    fn state_capabilities(&self);
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

/// The mark a sign-out leaves when someone had revoked this machine at the hub: the next sign-in
/// does not enroll it again. A join made here (`recovery::complete`) clears it.
const REVOKED_FILE: &str = "machine-join.revoked.json";
/// A sign-out's leave, marked before it starts and cleared when it is done (or a sign-in comes).
pub(super) const LEAVE_FILE: &str = "machine-join.leave.json";

/// One hub row of this box (a stale row, or a revoked machine's mark).
#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct StaleRow {
    machine_id: String,
    hub_origin: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    host_fingerprint: Option<String>,
    /// A stale row's own credential, when the hub did not answer its revoke: asked again with it
    /// until the hub says it is revoked. Never sent anywhere else.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    credential: Option<String>,
}

fn write_row(home: &Path, file: &str, record: &MachineCredential, credential: bool) -> Result<()> {
    let row = StaleRow {
        machine_id: record.machine_id.clone(),
        hub_origin: record.hub_origin.clone(),
        host_fingerprint: record.host_fingerprint.clone(),
        credential: credential.then(|| record.credential.clone()),
    };
    recovery::write_durable(&home.join(file), &serde_json::to_vec(&row)?, true)
}

/// Records `record`'s hub row as stale; with `retry`, with its credential, so its own revoke is
/// asked again.
fn record_stale(home: &Path, record: &MachineCredential, retry: bool) -> Result<()> {
    write_row(home, STALE_FILE, record, retry)
}

/// Asks the hub again to revoke the stale row this box's sign-out could not, with its own
/// credential (`revoke`), and drops the credential once the hub says it is revoked. Rows without
/// one, or a copied home's, are left to a sign-in's revoke by id. True when none is left to ask.
async fn revoke_stale_own<F, Fut>(home: &Path, current: Option<&str>, revoke: &F) -> bool
where
    F: Fn(MachineCredential) -> Fut,
    Fut: Future<Output = leave::HubAnswer>,
{
    let Ok(file) = crate::config::private_state_file(&home.join(STALE_FILE)) else { return true };
    let Ok(row) = serde_json::from_reader::<_, StaleRow>(file) else { return true };
    let Some(credential) =
        row.credential.clone().filter(|_| row.host_fingerprint.as_deref() == current)
    else {
        return true;
    };
    let answer = revoke(MachineCredential {
        credential,
        machine_id: row.machine_id.clone(),
        hub_origin: row.hub_origin.clone(),
        host_fingerprint: row.host_fingerprint.clone(),
        ..Default::default()
    })
    .await;
    if !answer.revoked() {
        tracing::warn!(hub = answer.label(), "sign-out leave: the stale row is not revoked yet");
        return false;
    }
    match std::fs::remove_file(home.join(STALE_FILE)) {
        Ok(()) => true,
        Err(e) => e.kind() == std::io::ErrorKind::NotFound,
    }
}

/// The row in `file` this box's own sign-out left on `hub`, if any (a copied home's is not this
/// box's).
fn read_row(home: &Path, file: &str, hub: &str, current: Option<&str>) -> Option<StaleRow> {
    let file = crate::config::private_state_file(&home.join(file)).ok()?;
    let row: StaleRow = serde_json::from_reader(file).ok()?;
    (row.host_fingerprint.as_deref() == current
        && origin(Some(row.hub_origin.clone())).ok().as_deref() == Some(hub))
    .then_some(row)
}

fn stale_row(home: &Path, hub: &str, current: Option<&str>) -> Option<StaleRow> {
    read_row(home, STALE_FILE, hub, current)
}

/// Ends the revoked mark: the person joined this machine again themselves.
pub(super) fn clear_revoked(home: &Path) {
    remove_mark(home, REVOKED_FILE);
}

fn remove_mark(home: &Path, file: &str) {
    match std::fs::remove_file(home.join(file)) {
        Ok(()) => {}
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        Err(e) => tracing::warn!(file, "sign-in enroll: a mark stayed: {e}"),
    }
}

/// Whether a sign-out's leave is not finished yet (the daemon finishes it at start).
/// Also when a revoke the hub did not answer is still to be asked again (a sign-in's join
/// proposal a sign-out set aside, or a stale row).
pub(crate) fn leave_pending() -> bool {
    let home = state_dir();
    [LEAVE_FILE, recovery::RETIRED, STALE_FILE]
        .iter()
        .any(|file| std::fs::symlink_metadata(home.join(file)).is_ok())
}

/// Marks a sign-out's leave. A mark that already says its local cleanup began keeps saying so.
fn mark_leave(home: &Path) -> Result<()> {
    if leave_removing(home) {
        return Ok(());
    }
    crate::config::private_state_dir(home)?;
    recovery::write_durable(&home.join(LEAVE_FILE), b"{}", true)
}

/// Marks that the leave's local cleanup ([`leave::remove_local`]) begins: it marks the record
/// revoked first, and a cleanup cut short there must be finished, not read as a revoke at the hub.
fn mark_leave_removing(home: &Path) -> Result<()> {
    recovery::write_durable(&home.join(LEAVE_FILE), br#"{"removing":true}"#, true)
}

/// Whether a leave's local cleanup began and may not have finished.
fn leave_removing(home: &Path) -> bool {
    crate::config::private_state_file(&home.join(LEAVE_FILE))
        .ok()
        .and_then(|file| serde_json::from_reader::<_, Value>(file).ok())
        .is_some_and(|mark| mark.get("removing").and_then(Value::as_bool) == Some(true))
}

/// Takes the join lock in `home`, waiting up to [`LOCK_WAIT`] for a join or leave in progress.
pub(super) async fn wait_for_lock(home: &Path) -> Option<HeldLock> {
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
    // A sign-out whose local cleanup stopped part way left the record marked revoked: finished
    // first, so that mark is never read as a revoke at the hub.
    if leave_removing(home) && leave::remove_local(home).is_err() {
        return EnrollOutcome::Unavailable;
    }
    // Signed in again: a sign-out's leave not finished yet is not finished at all. What it set
    // aside or could not revoke is still revoked: those are the last join's, never this one's.
    remove_mark(home, LEAVE_FILE);
    let revoke_own = |record: MachineCredential| port.revoke_own(record);
    let _ = revoke_retired(home, &revoke_own).await;
    revoke_stale_own(home, current, &revoke_own).await;
    // A home copied from another box: marked, and this box given its own node key, before the
    // key is compared with the hub's rows below.
    if settle_clone_at(home, current).is_err() {
        return EnrollOutcome::Unavailable;
    }
    // A join whose redeem the hub took but whose local commit stopped: finished first, as what
    // began it, with nothing minted. One the hub never took waits for the mint below.
    if let Err(e) = port.resume().await {
        tracing::debug!("sign-in enroll: no join to finish: {e:#}");
    }
    let Ok(mut record) = load_at(home) else { return EnrollOutcome::Unavailable };
    // The last person's sign-in join, and another person signs in (an account switch whose
    // sign-out's leave acpmux never got): that person's leave is finished first, then this one
    // enrolls. A join made any other way, or someone else's revoked one, is left as it is.
    if let Some(theirs) = record.as_ref().filter(|record| {
        record.joined_by.as_deref() == Some(JOINED_BY_SIGN_IN)
            && !record.revoked
            && !copied_here(home, record, current)
            && matches!((user_id, record.user_id.as_deref()), (Some(mine), Some(theirs)) if mine != theirs)
    }) {
        tracing::info!(machine = %theirs.machine_id, "sign-in enroll: the last person's sign-in join leaves first");
        if mark_leave(home).is_err() {
            return EnrollOutcome::Unavailable;
        }
        if !leave_locked(home, current, &revoke_own).await.left {
            return EnrollOutcome::Unavailable;
        }
        record = None;
    }
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
            SelfCheck::Live => {
                if let Err(e) = port.repair_relay() {
                    tracing::warn!("sign-in enroll: the relay config was not repaired: {e:#}");
                }
                if record.capabilities.is_none() {
                    port.state_capabilities();
                }
                return EnrollOutcome::AlreadyJoined;
            }
            // Unreachable says nothing against the join here: it stays as it is.
            SelfCheck::Unavailable => return EnrollOutcome::AlreadyJoined,
            SelfCheck::Revoked => {
                let _ = save_at(home, &MachineCredential { revoked: true, ..record });
                return EnrollOutcome::Revoked;
            }
            // Dead at the hub, never revoked by anyone: this box enrolls again in its place.
            SelfCheck::Unknown => replace = true,
        }
    }
    // Someone revoked this machine at the hub, and its sign-out found it so: it stays out.
    if read_row(home, REVOKED_FILE, hub, current).is_some() {
        return EnrollOutcome::Revoked;
    }
    // The row this box's last sign-out could not revoke: revoke it now with the person's token,
    // so the machine never shows twice. A failed list or revoke does not stop the enroll.
    if let Some(stale) = stale_row(home, hub, current)
        && stale.credential.is_none()
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
    // A relay the person set up stays theirs: a join here would replace it with the join's.
    match own_relay_at(&home.join("config.json"), hub) {
        Ok(false) => {}
        Ok(true) => return EnrollOutcome::OwnRelay,
        Err(e) => {
            tracing::warn!("sign-in enroll: config.json was not read: {e:#}");
            return EnrollOutcome::Unavailable;
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

/// Writes the joined `meshRelay` into `home`'s config.json when it has none, for the joined
/// record on `hub` (a relay of the person's own is left as it is).
fn repair_relay_at(home: &Path, hub: &str, current: Option<&str>) -> Result<()> {
    let config_path = home.join("config.json");
    if crate::config::Config::load_from(&config_path)?.mesh_relay.is_some() {
        return Ok(());
    }
    let Some(record) = load_at(home)? else { return Ok(()) };
    if record.revoked
        || copied_here(home, &record, current)
        || origin(Some(record.hub_origin.clone())).ok().as_deref() != Some(hub)
    {
        return Ok(());
    }
    configure_mesh_relay_at(&config_path, hub)
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
        // A new proposal is the sign-in's; a pending one finishes as what began it (a pasted
        // join line's stays the person's).
        recovery::join(
            Some(self.hub.clone()),
            Some(name.to_owned()),
            replace,
            Report::Quiet,
            Some(token.as_str().to_owned()),
            Some(JOINED_BY_SIGN_IN),
        )
        .await
    }

    async fn resume(&self) -> Result<()> {
        if recovery::pending_origin()?.is_none() {
            return Ok(());
        }
        recovery::join(None, None, false, Report::Quiet, None, None).await
    }

    fn repair_relay(&self) -> Result<()> {
        repair_relay_at(&state_dir(), &self.hub, host_fingerprint::current().as_deref())
    }

    async fn revoke_own(&self, record: MachineCredential) -> leave::HubAnswer {
        revoke_self(record).await
    }

    fn state_capabilities(&self) {
        super::self_capabilities::state_on_sign_in();
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

/// How long a leave waits for the hub's answer to its revoke; past it, the row is recorded stale.
const REVOKE_WAIT: std::time::Duration = std::time::Duration::from_secs(10);

/// The hub's answer to this machine revoking itself, waited for at most [`REVOKE_WAIT`].
async fn revoke_self(record: MachineCredential) -> leave::HubAnswer {
    tokio::time::timeout(REVOKE_WAIT, leave::revoke_at_hub(&record))
        .await
        .unwrap_or_else(|_| leave::HubAnswer::Unavailable("no answer in time".to_owned()))
}

/// Signing out: leaves the hub only when signing in joined this machine (`joined_by: "sign-in"`).
/// A pair-code or join-line machine stays joined, and a revoked one stays revoked. The leave is
/// marked first, so one cut short is finished at the next daemon start ([`finish_leave_at_start`]).
pub(crate) async fn leave_if_auto() -> LeaveOutcome {
    let home = state_dir();
    if let Err(e) = mark_leave(&home) {
        tracing::warn!("sign-out leave: not marked: {e:#}");
    }
    leave_marked(&home, host_fingerprint::current().as_deref(), false, revoke_self).await
}

/// At daemon start, before the mesh relay: a sign-out's leave the last run did not finish. None
/// when there is none.
pub(crate) async fn finish_leave_at_start() -> Option<LeaveOutcome> {
    if !leave_pending() {
        return None;
    }
    let current = host_fingerprint::current();
    Some(leave_marked(&state_dir(), current.as_deref(), true, revoke_self).await)
}

/// Whether the mesh relay may start after a start's leave: not when the join left, nor when the
/// leave is still not finished.
pub(crate) fn relay_may_start(outcome: &LeaveOutcome) -> bool {
    !outcome.left && outcome.kept != Some("busy")
}

/// Revokes the credential of the sign-in's join proposal a sign-out set aside in `home`, if any
/// (`recovery::RETIRED`), and drops the proposal once the hub revoked it or never took it.
/// `Ok(revoked)`: none is left, and `revoked` is the credential this call revoked, if any.
async fn revoke_retired<F, Fut>(home: &Path, revoke: &F) -> Result<Option<String>, ()>
where
    F: Fn(MachineCredential) -> Fut,
    Fut: Future<Output = leave::HubAnswer>,
{
    let proposal = match recovery::retired_at(home) {
        Ok(None) => return Ok(None),
        Ok(Some(proposal)) => proposal,
        Err(_) => return Err(()),
    };
    let credential = proposal.credential.clone();
    let answer = revoke(proposal).await;
    if !answer.revoked() {
        tracing::warn!(
            hub = answer.label(),
            "sign-out leave: a sign-in's join proposal is not revoked yet; asked again at the next start"
        );
        return Err(());
    }
    recovery::drop_retired_at(home).map_err(|_| ())?;
    Ok(Some(credential))
}

/// The leave marked in `home`. With `only_marked` (a daemon start's), a sign-in that cleared the
/// mark since leaves nothing to do but ask again the revokes the hub did not answer.
async fn leave_marked<F, Fut>(
    home: &Path,
    current: Option<&str>,
    only_marked: bool,
    revoke: F,
) -> LeaveOutcome
where
    F: Fn(MachineCredential) -> Fut,
    Fut: Future<Output = leave::HubAnswer>,
{
    let Some(_lock) = wait_for_lock(home).await else { return kept("busy") };
    if only_marked && std::fs::symlink_metadata(home.join(LEAVE_FILE)).is_err() {
        // Signed in since: that sign-in's own proposal stays; only what was set aside is revoked.
        let _ = revoke_retired(home, &revoke).await;
        revoke_stale_own(home, current, &revoke).await;
        return kept("signedIn");
    }
    leave_locked(home, current, &revoke).await
}

fn kept(why: &'static str) -> LeaveOutcome {
    LeaveOutcome { left: false, kept: Some(why), hub: None }
}

/// A sign-out's leave of the join in `home`, marked ([`mark_leave`]), with the join lock held. A
/// sign-in's join proposal still pending is set aside where no join resumes it, and its
/// credential is revoked at the hub; the mark stays until that revoke is done. The hub is asked
/// to revoke the joined credential with the credential itself (`revoke`), unless that same
/// credential was just revoked as the proposal's (`recovery::complete` writes the record before
/// it removes the proposal). The join here goes either way: a row the hub did not revoke is
/// recorded so it is asked again, and a machine someone had revoked there is marked so no sign-in
/// enrolls it again on its own. The mark stays until the leave is done, and says when its local
/// cleanup began, so a cleanup cut short is finished.
async fn leave_locked<F, Fut>(home: &Path, current: Option<&str>, revoke: &F) -> LeaveOutcome
where
    F: Fn(MachineCredential) -> Fut,
    Fut: Future<Output = leave::HubAnswer>,
{
    if recovery::retire_sign_in_pending_at(home, current).is_err() {
        return kept("busy");
    }
    let retired = revoke_retired(home, revoke).await;
    let stale_done = revoke_stale_own(home, current, revoke).await;
    let finish = || {
        if retired.is_ok() && stale_done {
            remove_mark(home, LEAVE_FILE);
        }
    };
    let done = |why| {
        finish();
        kept(why)
    };
    let record = match load_at(home) {
        Ok(Some(record)) => record,
        Ok(None) => return done("notJoined"),
        Err(_) => return kept("busy"),
    };
    if record.joined_by.as_deref() != Some(JOINED_BY_SIGN_IN) {
        return done("notBySignIn");
    }
    if record.revoked {
        // This leave's own cleanup marked it revoked and stopped: finished now.
        if leave_removing(home) {
            if leave::remove_local(home).is_err() {
                return kept("busy");
            }
            finish();
            return LeaveOutcome { left: true, kept: None, hub: None };
        }
        // A revoked machine stays so: its record keeps the next sign-in from enrolling it again.
        return done("revoked");
    }
    let answer = if copied_here(home, &record, current) {
        None
    } else if retired.as_ref().is_ok_and(|done| done.as_deref() == Some(record.credential.as_str()))
    {
        // The proposal's revoke above was this credential's: asking again would read as someone
        // else's revoke.
        Some(leave::HubAnswer::Revoked)
    } else {
        Some(revoke(record.clone()).await)
    };
    // Someone revoked it at the hub before this sign-out: no sign-in brings it back on its own.
    if matches!(answer, Some(leave::HubAnswer::AlreadyGone { revoked: true }))
        && write_row(home, REVOKED_FILE, &record, false).is_err()
    {
        return kept("busy");
    }
    // Not revoked at the hub: recorded so it is revoked later. A revoke that went unanswered
    // keeps the credential, so it is asked again with it at each start and sign-in.
    if let Some(answer) = answer.as_ref().filter(|answer| !answer.revoked()) {
        let retry = matches!(answer, leave::HubAnswer::Unavailable(_));
        if record_stale(home, &record, retry).is_err() {
            return kept("busy");
        }
    }
    if mark_leave_removing(home).is_err() || leave::remove_local(home).is_err() {
        return kept("busy");
    }
    finish();
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
        mark_leave(home).unwrap();
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
        record_stale(home.path(), &lost, false).unwrap();
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
        let mut pending = json!({
            "version": 1, "credential": "cmm_pending", "hub": HUB, "name": "box",
            "hostname": "box", "platform": "linux", "wg_public_key": "key", "prior": null,
            "host_fingerprint": fingerprint,
        });
        if let Some(joined_by) = joined_by {
            pending["joined_by"] = json!(joined_by);
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
        mark_leave(home.path()).unwrap();
        let left = leave_marked(home.path(), Some("box-a"), false, unanswered).await;
        assert_eq!(left.kept, Some("notJoined"));
        assert_eq!(*asked.lock().unwrap(), vec![("cmm_pending".to_owned(), HUB.to_owned())]);
        // Set aside at once, so no sign-in (by anyone) resumes it as this person's join.
        assert!(!home.path().join("machine-join.pending.json").exists());
        assert!(home.path().join(recovery::RETIRED).exists());
        // Not revoked yet: the mark stays, so the next start asks again.
        assert!(home.path().join(LEAVE_FILE).exists());
        let at_start =
            leave_marked(home.path(), Some("box-a"), true, |_| async { leave::HubAnswer::Revoked })
                .await;
        assert_eq!(at_start.kept, Some("notJoined"));
        assert!(relay_may_start(&at_start));
        assert!(!home.path().join(recovery::RETIRED).exists());
        assert!(!home.path().join(LEAVE_FILE).exists());

        // A sign-in since cleared the mark: a start still revokes what was set aside, and the
        // new sign-in's own proposal stays.
        let home = tempfile::tempdir().unwrap();
        pending_join(home.path(), Some(JOINED_BY_SIGN_IN), "box-a");
        mark_leave(home.path()).unwrap();
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
        assert!(!home.path().join(recovery::RETIRED).exists());
        assert!(home.path().join("machine-join.pending.json").exists());

        // A pasted join line's proposal, and one copied from another box, are not this
        // sign-out's: they stay, and the hub is not asked.
        for (joined_by, fingerprint) in [(None, "box-a"), (Some(JOINED_BY_SIGN_IN), "box-b")] {
            let home = tempfile::tempdir().unwrap();
            pending_join(home.path(), joined_by, fingerprint);
            let calls = AtomicUsize::new(0);
            mark_leave(home.path()).unwrap();
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
        mark_leave(home.path()).unwrap();
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
        mark_leave(home.path()).unwrap();
        let left = leave_marked(home.path(), Some("box-a"), false, |_| async {
            leave::HubAnswer::Revoked
        })
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
        mark_leave(home.path()).unwrap();
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
        assert!(!home.path().join(REVOKED_FILE).exists(), "no tombstone for its own revoke");
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
        let stale: StaleRow =
            serde_json::from_slice(&std::fs::read(home.path().join(STALE_FILE)).unwrap()).unwrap();
        assert_eq!(stale.credential.as_deref(), Some("cmm_old"));
        // A start with the hub still down: asked again, kept.
        let at_start = leave_marked(home.path(), Some("box-a"), true, |_| async {
            leave::HubAnswer::Unavailable("down".into())
        })
        .await;
        assert!(relay_may_start(&at_start), "B's relay runs meanwhile");
        assert!(home.path().join(STALE_FILE).exists());
        // The hub answers: revoked with A's own credential, and dropped.
        let asked = Mutex::new(Vec::new());
        leave_marked(home.path(), Some("box-a"), true, |record: MachineCredential| {
            asked.lock().unwrap().push(record.credential.clone());
            async { leave::HubAnswer::Revoked }
        })
        .await;
        assert_eq!(*asked.lock().unwrap(), vec!["cmm_old".to_owned()]);
        assert!(!home.path().join(STALE_FILE).exists());
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
        mark_leave(home.path()).unwrap();
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
        mark_leave(home.path()).unwrap();
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
            json!({"meshRelay": {"url": "https://own.example", "tokenCommand": ["true"]}})
                .to_string(),
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
            std::fs::write(home.join("config.json"), json!({"meshRelay": relay}).to_string())
                .unwrap();
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
            let at_start = leave_marked(home.path(), Some("box-a"), true, |_| async {
                leave::HubAnswer::Revoked
            })
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

    #[test]
    fn a_dev_build_tag_names_the_machine_apart() {
        let base = crate::pairing::machine_name();
        assert_eq!(enroll_name(None), base);
        assert_eq!(enroll_name(Some("  ")), base);
        assert_eq!(enroll_name(Some("Sign In!")), format!("{base}-signin"));
        assert!(enroll_name(Some(&"x".repeat(200))).len() <= 63);
    }
}
