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
//!   revoke at the hub. Its revoke is marked before it is sent, so a revoke the hub committed
//!   before this box stopped is read as this box's own, never as someone else's: the next
//!   sign-in still enrolls the machine.
//! - Signing out stops the daemon's relay only when the leave removed the join's relay from
//!   config.json; a relay the person set up, or another hub's, keeps running.
//! - A sign-in's join left pending (the hub took its redeem, its answer or probe never came) goes
//!   with a sign-out too: the proposal is set aside where no join resumes it (a later sign-in by
//!   another person would otherwise finish it as this one's), and its credential is revoked at
//!   the hub with the credential itself. Until the hub says so, each start asks again.
//! - A revoke the hub did not answer is asked again with the machine's own credential, at each
//!   start and each sign-in until the hub says it is revoked, whoever signs in meanwhile. Each
//!   such credential and row is queued on its own (`to_revoke.rs`): a later sign-out's never
//!   replaces an earlier one's.
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
    /// Joined with no account recorded (an older join, or one whose hub named none), or asked with
    /// no account: whose it is is not known, so it is left alone, and no join is made.
    OwnerUnknown,
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
    /// The signed-in person's id (the local app's, person-proven): the join is recorded under it.
    /// With none, nothing is enrolled ([`EnrollOutcome::OwnerUnknown`]).
    pub user_id: Option<String>,
    /// A DEV build's tag, added to the machine's name so its join is told apart.
    pub build_tag: Option<String>,
}

/// What a sign-out's leave did.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct LeaveOutcome {
    pub left: bool,
    /// Why nothing was left: `notJoined`, `notBySignIn`, `revoked`, `otherUser` (joined for
    /// another account), `ownerUnknown` (no account recorded, or none named signing out),
    /// `signedIn` (a sign-in since replaced the sign-out) or `busy` (not finished: the next
    /// daemon start finishes it).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub kept: Option<&'static str>,
    /// What the hub said to the revoke, when one was asked.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub hub: Option<&'static str>,
    /// The leave left config.json with no relay of the join's: the daemon stops its running relay
    /// only then. A relay the person set up, or another hub's, which the leave keeps, keeps
    /// running.
    #[serde(skip)]
    pub relay_removed: bool,
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
    /// Redeems `token` as this machine (`recovery::join`), writing the record under `owner`, the
    /// account that minted it.
    fn redeem(
        &self,
        name: &str,
        token: Zeroizing<String>,
        replace: bool,
        owner: &str,
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

/// Whose a join is to the account acting on it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum Owner {
    /// Recorded under this account.
    Mine,
    /// Recorded under another account.
    Theirs,
    /// No account recorded, or none acting: never read as this account's.
    Unknown,
}

/// Whose a join recorded under `recorded` is to `account`. Every enroll, leave and retire of a
/// sign-in's join asks this: only [`Owner::Mine`] acts on it, and a missing id on either side is
/// [`Owner::Unknown`], never a match.
pub(super) fn owner_of(recorded: Option<&str>, account: Option<&str>) -> Owner {
    match (recorded, account) {
        (Some(recorded), Some(account)) if recorded == account => Owner::Mine,
        (Some(_), Some(_)) => Owner::Theirs,
        _ => Owner::Unknown,
    }
}

/// [`owner_of`] for a leave by every account in `accounts` (a leave mark's): [`Owner::Mine`]
/// when the join is recorded under one of them, [`Owner::Unknown`] when under none or with no
/// account named.
pub(super) fn owner_among(recorded: Option<&str>, accounts: &[String]) -> Owner {
    if accounts.is_empty() {
        return Owner::Unknown;
    }
    if accounts.iter().any(|account| owner_of(recorded, Some(account)) == Owner::Mine) {
        return Owner::Mine;
    }
    owner_of(recorded, accounts.first().map(String::as_str))
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

/// A sign-out's leave, marked before it starts and cleared when it is done (or a sign-in comes).
pub(super) const LEAVE_FILE: &str = "machine-join.leave.json";

/// Queues `record`'s hub row, which the hub did not revoke, so it is revoked later; with
/// `retry`, with its credential, so its own revoke is asked again. Never a match on the node key
/// or the host name alone, which a copied home or a twin machine shares.
fn record_stale(home: &Path, record: &MachineCredential, retry: bool) -> Result<()> {
    to_revoke::queue(home, &to_revoke::Row::of(record, retry))
}

/// Asks the hub again to revoke each credential this box queued (a stale row's, a set-aside
/// join proposal's), with the credential itself (`revoke`), and drops each once the hub says it
/// is revoked or gone. Rows without one, or a copied home's, are left to a sign-in's revoke by
/// id. True when none of this box's is left to ask.
async fn revoke_queued_own<F, Fut>(home: &Path, current: Option<&str>, revoke: &F) -> bool
where
    F: Fn(MachineCredential) -> Fut,
    Fut: Future<Output = leave::HubAnswer>,
{
    let Ok(queued) = to_revoke::queued(home) else { return false };
    let mut done = true;
    for (path, row) in queued {
        if row.host_fingerprint.as_deref() != current {
            continue;
        }
        let Some(record) = row.as_record() else { continue };
        let answer = revoke(record).await;
        if !answer.revoked() {
            tracing::warn!(hub = answer.label(), "sign-out leave: a queued revoke is not done yet");
            done = false;
        } else if let Err(e) = to_revoke::remove(&path) {
            tracing::warn!("sign-out leave: a revoked entry stayed queued: {e:#}");
            done = false;
        }
    }
    done
}

fn remove_mark(home: &Path, file: &str) {
    match crate::home_fs::remove_file(home.join(file)) {
        Ok(()) => {}
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        Err(e) => tracing::warn!(file, "sign-in enroll: a mark stayed: {e}"),
    }
}

/// Whether a sign-out's leave is not finished yet (the daemon finishes it at start).
/// Also when a revoke the hub did not answer is still queued (a sign-in's join proposal a
/// sign-out set aside, or a stale row).
pub(crate) fn leave_pending() -> bool {
    let home = state_dir();
    std::fs::symlink_metadata(home.join(LEAVE_FILE)).is_ok() || to_revoke::any_queued(&home)
}

/// A sign-out's leave mark (`LEAVE_FILE`): every account signing out whose leave is not finished
/// (a durable intent, written before the leave reaches the daemon: [`record_leave_intent`]), and
/// whether the leave's local cleanup began.
#[derive(Debug, Default, Clone, PartialEq, Eq, Serialize, serde::Deserialize)]
struct LeaveMark {
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    accounts: Vec<String>,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    removing: bool,
}

/// The leave mark in `home`: None when there is none, an empty one when it does not parse.
fn read_mark(home: &Path) -> Option<LeaveMark> {
    let path = home.join(LEAVE_FILE);
    std::fs::symlink_metadata(&path).ok()?;
    let mut mark: LeaveMark = crate::config::private_state_file(&path)
        .ok()
        .and_then(|file| serde_json::from_reader(file).ok())
        .unwrap_or_default();
    mark.accounts.retain(|account| safe_id(account).as_deref() == Some(account.as_str()));
    Some(mark)
}

fn write_mark(home: &Path, mark: &LeaveMark) -> Result<()> {
    crate::config::private_state_dir(home)?;
    recovery::write_durable(&home.join(LEAVE_FILE), &serde_json::to_vec(mark)?, true)
}

/// Marks a sign-out's leave by `account`, the account signing out, beside every account the mark
/// already names: a leave asked again with no account, or by another account, never drops one.
/// A mark that says its local cleanup began keeps saying so.
fn mark_leave(home: &Path, account: Option<&str>) -> Result<()> {
    let mut mark = read_mark(home).unwrap_or_default();
    if let Some(account) = account
        && !mark.accounts.iter().any(|named| named == account)
    {
        mark.accounts.push(account.to_owned());
    }
    write_mark(home, &mark)
}

/// The accounts a marked leave is for.
fn leave_accounts(home: &Path) -> Vec<String> {
    read_mark(home).map(|mark| mark.accounts).unwrap_or_default()
}

/// Marks that the leave's local cleanup ([`leave::remove_local`]) begins: it marks the record
/// revoked first, and a cleanup cut short there must be finished, not read as a revoke at the hub.
/// The accounts it names stay.
fn mark_leave_removing(home: &Path) -> Result<()> {
    let mark = read_mark(home).unwrap_or_default();
    write_mark(home, &LeaveMark { removing: true, ..mark })
}

/// Whether a leave's local cleanup began and may not have finished.
fn leave_removing(home: &Path) -> bool {
    read_mark(home).is_some_and(|mark| mark.removing)
}

/// The last sign-in's enroll here: which account, and when it began (Unix ms). A leave intent
/// from before it is stale.
pub(super) const SIGNED_IN_FILE: &str = "machine-join.signed-in.json";

#[derive(Debug, Clone, PartialEq, Eq, Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct SignedIn {
    account: String,
    at_ms: u64,
}

/// Now, in Unix milliseconds (the app's `--signed-out-at` is on the same clock).
pub(crate) fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |since| u64::try_from(since.as_millis()).unwrap_or(u64::MAX))
}

/// Notes, before an enroll touches the leave mark, that `account` signed in at `at_ms`: an
/// intent of that account's signing out from before then, written later, is stale
/// ([`record_leave_intent`]).
fn stamp_signed_in(home: &Path, account: &str, at_ms: u64) -> Result<()> {
    let stamp = SignedIn { account: account.to_owned(), at_ms };
    crate::config::private_state_dir(home)?;
    recovery::write_durable(&home.join(SIGNED_IN_FILE), &serde_json::to_vec(&stamp)?, true)
}

/// Whether `account` signed in here after `at_ms` (a tie is not: the intent is recorded).
fn signed_in_since(home: &Path, account: &str, at_ms: u64) -> bool {
    crate::config::private_state_file(&home.join(SIGNED_IN_FILE))
        .ok()
        .and_then(|file| serde_json::from_reader::<_, SignedIn>(file).ok())
        .is_some_and(|stamp| stamp.account == account && stamp.at_ms > at_ms)
}

/// Records that `account` signs out (`acpmux machine leave-intent`), with no daemon: the app
/// writes it before it sends its leave, so a leave the daemon never gets (it was down, or the app
/// quit first) is still finished as that account's, at the daemon's next start or by the next
/// leave, which may name no account (a launch signed out). Only that account's sign-in join
/// is left by it ([`owner_among`]).
///
/// `signed_out_at` (Unix ms; None: now, before the wait for the join lock) is when the sign-out
/// happened. An intent written after that account signed in again (its writer waited on the
/// lock while the new sign-in's enroll held it) is stale and not recorded: it never leaves the
/// newer join. False when it was stale.
pub(crate) async fn record_leave_intent(account: &str, signed_out_at: Option<u64>) -> Result<bool> {
    record_leave_intent_at(&state_dir(), account, signed_out_at).await
}

async fn record_leave_intent_at(
    home: &Path,
    account: &str,
    signed_out_at: Option<u64>,
) -> Result<bool> {
    let at = signed_out_at.unwrap_or_else(now_ms);
    let account = safe_id(account.trim()).ok_or_else(|| anyhow!("the user id is malformed"))?;
    let _lock = wait_for_lock(home)
        .await
        .ok_or_else(|| anyhow!("another join or leave holds this machine; try again"))?;
    if signed_in_since(home, &account, at) {
        tracing::info!("sign-out intent: that account signed in again since; not recorded");
        return Ok(false);
    }
    mark_leave(home, Some(&account))?;
    Ok(true)
}

/// Takes the join lock in `home`, waiting up to [`LOCK_WAIT`] for a join or leave in progress.
pub(super) async fn wait_for_lock(home: &Path) -> Option<HeldLock> {
    let take = async {
        loop {
            if let Ok(lock) =
                crate::config::private_state_dir(home).and_then(|()| join_lock_at(home))
            {
                return lock;
            }
            // timeout: short-gate: the step between tries at the join lock; LOCK_WAIT bounds the wait.
            tokio::time::sleep(std::time::Duration::from_millis(200)).await;
        }
    };
    tokio::time::timeout(LOCK_WAIT, take).await.ok()
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
    // No account: a join made now would be no one's, and one here is not known to be this one's.
    let Some(account) = user_id else { return EnrollOutcome::OwnerUnknown };
    // When this sign-in asked, before any wait: a sign-out after it, whose intent waits for the
    // lock this enroll holds, is still recorded.
    let asked_at = now_ms();
    let Some(_lock) = wait_for_lock(home).await else { return EnrollOutcome::Unavailable };
    // This account's sign-out intents from before it asked are stale from here on, even one
    // written after this enroll (its writer waited for this lock).
    if stamp_signed_in(home, account, asked_at).is_err() {
        return EnrollOutcome::Unavailable;
    }
    // A sign-out whose local cleanup stopped part way left the record marked revoked: finished
    // first, so that mark is never read as a revoke at the hub.
    if leave_removing(home) {
        if leave::remove_local(home, false).is_err() {
            return EnrollOutcome::Unavailable;
        }
        to_revoke::clear_self_revoke(home);
    }
    let revoke_own = |record: MachineCredential| port.revoke_own(record);
    // Signed in again: this account's sign-out not finished yet is not finished at all. Another
    // account's still is, and is finished first, as theirs: this sign-in never erases it. What a
    // sign-out set aside or could not revoke is still revoked: those are the last join's, never
    // this one's.
    let others: Vec<String> =
        leave_accounts(home).into_iter().filter(|named| named != account).collect();
    if others.is_empty() {
        remove_mark(home, LEAVE_FILE);
    } else {
        if write_mark(home, &LeaveMark { accounts: others.clone(), removing: false }).is_err() {
            return EnrollOutcome::Unavailable;
        }
        if leave_locked(home, current, &others, &revoke_own).await.kept == Some("busy") {
            return EnrollOutcome::Unavailable;
        }
    }
    revoke_queued_own(home, current, &revoke_own).await;
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
    // The last person's sign-in join, recorded under their account, and another person signs in
    // (an account switch whose sign-out's leave acpmux never got): that person's leave is
    // finished first, as theirs, then this one enrolls. A join made any other way, one recorded
    // under no account, or someone else's revoked one, is left as it is.
    if let Some(theirs) = record.as_ref().filter(|record| {
        record.joined_by.as_deref() == Some(JOINED_BY_SIGN_IN)
            && !record.revoked
            && !copied_here(home, record, current)
            && owner_of(record.user_id.as_deref(), Some(account)) == Owner::Theirs
    }) {
        tracing::info!(machine = %theirs.machine_id, "sign-in enroll: the last person's sign-in join leaves first");
        let last: Vec<String> = theirs.user_id.clone().into_iter().collect();
        if mark_leave(home, last.first().map(String::as_str)).is_err() {
            return EnrollOutcome::Unavailable;
        }
        if !leave_locked(home, current, &last, &revoke_own).await.left {
            return EnrollOutcome::Unavailable;
        }
        record = None;
    }
    let mut replace = false;
    if let Some(record) = record.filter(|record| !copied_here(home, record, current)) {
        // This box's own sign-out was revoking this credential when it stopped: a revoke the
        // hub holds for it is that sign-out's, never someone else's.
        let own = to_revoke::self_revoking(home, &record);
        let check = if record.revoked {
            if !own {
                return EnrollOutcome::Revoked;
            }
            SelfCheck::Revoked
        } else {
            if origin(Some(record.hub_origin.clone())).ok().as_deref() != Some(hub) {
                return EnrollOutcome::OtherHub;
            }
            // Only this account's join is this sign-in's: one recorded under no account is not
            // read as anyone's.
            match owner_of(record.user_id.as_deref(), Some(account)) {
                Owner::Mine => {}
                Owner::Theirs => return EnrollOutcome::OtherUser,
                Owner::Unknown => return EnrollOutcome::OwnerUnknown,
            }
            port.check_self(&record).await
        };
        match check {
            SelfCheck::Live => {
                // The sign-out's revoke never reached the hub: this sign-in keeps the join.
                if own {
                    to_revoke::clear_self_revoke(home);
                }
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
            // That sign-out's revoke reached the hub before it stopped: its cleanup is finished
            // here, and this sign-in enrolls the machine again.
            SelfCheck::Revoked if own => {
                if leave::remove_local(home, false).is_err() {
                    return EnrollOutcome::Unavailable;
                }
                to_revoke::clear_self_revoke(home);
            }
            SelfCheck::Revoked => {
                let _ = save_at(home, &MachineCredential { revoked: true, ..record });
                return EnrollOutcome::Revoked;
            }
            // Dead at the hub, never revoked by anyone: this box enrolls again in its place.
            SelfCheck::Unknown => replace = true,
        }
    }
    // Someone revoked this machine at the hub, and its sign-out found it so: it stays out.
    if to_revoke::revoked_on(home, hub, current) {
        return EnrollOutcome::Revoked;
    }
    // The rows this box's sign-outs could not revoke on this hub: revoked now with the person's
    // token, each by its id, so the machine never shows twice. A failed list or revoke does not
    // stop the enroll; what stays is asked again at the next sign-in.
    let stale: Vec<_> = to_revoke::queued(home)
        .unwrap_or_default()
        .into_iter()
        .filter(|(_, row)| row.credential.is_none() && row.on(hub, current))
        .collect();
    if !stale.is_empty()
        && let Ok(rows) = port.credentials().await
    {
        for (path, stale) in stale {
            let live = rows.iter().any(|(id, _, revoked)| *id == stale.machine_id && !revoked);
            let gone = !live || port.revoke(&stale.machine_id).await.is_ok();
            if !gone || to_revoke::remove(&path).is_err() {
                tracing::warn!(machine = %stale.machine_id, "sign-in enroll: a stale row stayed");
            }
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
    match port.redeem(name, token, replace, account).await {
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

    async fn redeem(
        &self,
        name: &str,
        token: Zeroizing<String>,
        replace: bool,
        owner: &str,
    ) -> Result<()> {
        // A new proposal is the sign-in's, under the account that minted it; a pending one
        // finishes as what began it (a pasted join line's stays the person's).
        recovery::join(
            Some(self.hub.clone()),
            Some(name.to_owned()),
            replace,
            Report::Quiet,
            Some(token.as_str().to_owned()),
            Some(recovery::Began { joined_by: JOINED_BY_SIGN_IN, owner }),
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
// timeout: a leave never hangs on the hub; past it the row is recorded stale and revoked later.
const REVOKE_WAIT: std::time::Duration = std::time::Duration::from_secs(10);

/// The hub's answer to this machine revoking itself, waited for at most [`REVOKE_WAIT`].
async fn revoke_self(record: MachineCredential) -> leave::HubAnswer {
    tokio::time::timeout(REVOKE_WAIT, leave::revoke_at_hub(&record))
        .await
        .unwrap_or_else(|_| leave::HubAnswer::Unavailable("no answer in time".to_owned()))
}

/// Signing out `account`: leaves the hub only when signing in joined this machine
/// (`joined_by: "sign-in"`) for that account. A pair-code or join-line machine stays joined, a
/// revoked one stays revoked, and one joined for another account, or for none known, stays the
/// way it is. The leave is marked first, with its account, so one cut short is finished at the
/// next daemon start ([`finish_leave_at_start`]).
pub(crate) async fn leave_if_auto(account: Option<&str>) -> LeaveOutcome {
    let home = state_dir();
    let account = account.and_then(safe_id);
    let current = host_fingerprint::current();
    leave_asked(&home, current.as_deref(), account.as_deref(), revoke_self).await
}

/// A sign-out's leave by `account`, or with no account (a launch signed out), asked of the daemon:
/// marked, with the join lock held, beside the accounts an earlier intent or leave named, then
/// left as every one of them.
async fn leave_asked<F, Fut>(
    home: &Path,
    current: Option<&str>,
    account: Option<&str>,
    revoke: F,
) -> LeaveOutcome
where
    F: Fn(MachineCredential) -> Fut,
    Fut: Future<Output = leave::HubAnswer>,
{
    // Marked first, so a leave that waits too long here is finished at the next start.
    if let Err(e) = mark_leave(home, account) {
        tracing::warn!("sign-out leave: not marked: {e:#}");
    }
    let Some(_lock) = wait_for_lock(home).await else { return kept("busy") };
    let mut accounts = leave_accounts(home);
    if let Some(account) = account
        && !accounts.iter().any(|named| named == account)
    {
        accounts.push(account.to_owned());
    }
    leave_locked(home, current, &accounts, &revoke).await
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

/// Whether the mesh relay may start after a start's leave: not while the leave is still not
/// finished, nor when it removed the join's relay. A relay the person set up, or another hub's,
/// which the leave keeps in config.json, starts.
pub(crate) fn relay_may_start(outcome: &LeaveOutcome) -> bool {
    outcome.kept != Some("busy") && !(outcome.left && outcome.relay_removed)
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
        revoke_queued_own(home, current, &revoke).await;
        return kept("signedIn");
    }
    let accounts = leave_accounts(home);
    leave_locked(home, current, &accounts, &revoke).await
}

fn kept(why: &'static str) -> LeaveOutcome {
    LeaveOutcome { left: false, kept: Some(why), hub: None, relay_removed: false }
}

/// A leave that removed the join here: `removed` is what its cleanup removed.
fn left(home: &Path, removed: &[&str], hub: Option<&'static str>) -> LeaveOutcome {
    // Removed now, or by a cleanup of this leave's cut short before: either way none is left.
    let relay_removed = removed.contains(&"meshRelay") || !leave::relay_configured(home);
    LeaveOutcome { left: true, kept: None, hub, relay_removed }
}

/// A sign-out's leave by `accounts` (every account its mark names) of the join in `home`, marked
/// ([`mark_leave`]), with the join lock held. Only what signing in made for one of them
/// ([`owner_among`] is [`Owner::Mine`]) is left: a join or proposal of another account's, or of
/// none known, stays. A sign-in's join proposal
/// still pending is set aside where no join resumes it, its credential
/// queued to be revoked at the hub (`to_revoke`); the mark stays until every queued revoke of
/// this box is done. The hub is asked to revoke the joined credential with the credential itself
/// (`revoke`), after a durable mark says this box is revoking it, so a revoke the hub committed
/// before this box stopped is read as this leave's own when asked again. The join here goes
/// either way: a row the hub did not revoke is queued so it is asked again, and a machine
/// someone had revoked there is marked so no sign-in enrolls it again on its own. The mark stays
/// until the leave is done, and says when its local cleanup began, so a cleanup cut short is
/// finished.
async fn leave_locked<F, Fut>(
    home: &Path,
    current: Option<&str>,
    accounts: &[String],
    revoke: &F,
) -> LeaveOutcome
where
    F: Fn(MachineCredential) -> Fut,
    Fut: Future<Output = leave::HubAnswer>,
{
    if recovery::retire_sign_in_pending_at(home, current, accounts).is_err() {
        return kept("busy");
    }
    let queued_done = revoke_queued_own(home, current, revoke).await;
    let finish = || {
        if queued_done {
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
    // This box's sign-out was already revoking this credential when it stopped.
    let own = to_revoke::self_revoking(home, &record);
    if record.revoked {
        // This leave's own cleanup marked it revoked and stopped, or the hub's 401 to this
        // leave's own revoke did: finished now.
        if leave_removing(home) || own {
            let Ok(removed) = leave::remove_local(home, false) else { return kept("busy") };
            to_revoke::clear_self_revoke(home);
            finish();
            return left(home, &removed, None);
        }
        // A revoked machine stays so: its record keeps the next sign-in from enrolling it again.
        return done("revoked");
    }
    // Another account's join, or one recorded under none: this sign-out never revokes it. The
    // mark goes with it only as an ordinary finished leave does: its accounts were read above
    // (never dropped for a leave that named none), and nothing here is any of theirs.
    match owner_among(record.user_id.as_deref(), accounts) {
        Owner::Mine => {}
        Owner::Theirs => return done("otherUser"),
        Owner::Unknown => return done("ownerUnknown"),
    }
    let copy = copied_here(home, &record, current);
    let answer = if copy {
        None
    } else {
        if to_revoke::mark_self_revoke(home, &record).is_err() {
            return kept("busy");
        }
        Some(match revoke(record.clone()).await {
            // Asked again after a stop: the revoke the hub holds is this leave's own.
            leave::HubAnswer::AlreadyGone { revoked: true } if own => leave::HubAnswer::Revoked,
            answer => answer,
        })
    };
    // Someone revoked it at the hub before this sign-out: no sign-in brings it back on its own.
    if matches!(answer, Some(leave::HubAnswer::AlreadyGone { revoked: true }))
        && to_revoke::mark_revoked(home, &record).is_err()
    {
        return kept("busy");
    }
    // Not revoked at the hub: queued so it is revoked later. A revoke that went unanswered
    // keeps the credential, so it is asked again with it at each start and sign-in.
    if let Some(answer) = answer.as_ref().filter(|answer| !answer.revoked()) {
        let retry = matches!(answer, leave::HubAnswer::Unavailable(_));
        if record_stale(home, &record, retry).is_err() {
            return kept("busy");
        }
    }
    if mark_leave_removing(home).is_err() {
        return kept("busy");
    }
    let Ok(removed) = leave::remove_local(home, copy) else { return kept("busy") };
    to_revoke::clear_self_revoke(home);
    finish();
    left(home, &removed, answer.map(|answer| answer.label()))
}

#[cfg(all(test, unix))]
mod tests;
