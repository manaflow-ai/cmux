//! A durable client-proposed credential closes the redeem/local-commit gap.
//! Only the final store feeds the relay. Pending never contains a join token.
use super::*;
use base64::Engine as _;
use cmux_json::JsonSet as _;
use std::io::Write;
use std::path::Path;
use zeroize::Zeroizing;

const FILE: &str = "machine-join.pending.json";
#[derive(Serialize, Deserialize)]
struct Pending {
    version: u8,
    credential: String,
    hub: String,
    name: String,
    hostname: String,
    platform: String,
    wg_public_key: String,
    prior: Option<MachineCredential>,
    /// The box this proposal was made on (`host_fingerprint`). A pending join copied to
    /// another box is set aside unsent: its proposed credential is the original box's.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    host_fingerprint: Option<String>,
    /// What began this join (`joined_by` of the record it completes): `sign-in` for a sign-in's
    /// enroll, None for a pasted join line. Kept here so a join resumed later, by whatever
    /// asks, completes as what began it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    joined_by: Option<String>,
    /// The capabilities its redeem sends (`machine_capabilities`). None on an older build's
    /// pending: its redeem, if done, sent none.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    capabilities: Option<Vec<String>>,
    /// The account a sign-in's join is for: the signed-in person who minted its token. The
    /// record it completes is recorded under it, whatever the hub's redeem names. None on a
    /// pasted join line's, and on an older build's: that record names no account.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    owner: Option<String>,
}

/// What began a join made by signing in: its `joined_by`, and the account that minted its token.
pub(super) struct Began<'a> {
    pub joined_by: &'a str,
    pub owner: &'a str,
}

/// The pending file of a join made on another box, kept beside unread.
const COPIED: &str = "machine-join.pending.copied.json";

/// Sets aside a pending join proposed on another box, before anything could send its
/// credential. A pending file with no fingerprint (an older build's) cannot be told apart and
/// is kept and resumed as before; the daemon-start check covers the record it completes. The caller
/// holds the join lock.
fn set_aside_copied_pending(current: Option<&str>) -> Result<bool> {
    let Some(p) = read()? else { return Ok(false) };
    let copied = matches!((p.host_fingerprint.as_deref(), current), (Some(made), Some(here)) if made != here);
    if copied {
        std::fs::rename(state_dir().join(FILE), state_dir().join(COPIED))
            .map_err(|_| store_error())?;
        sync_ancestors(&state_dir()).map_err(|_| store_error())?;
    }
    Ok(copied)
}

/// Sets aside the sign-in's join proposal in `home`, if one is pending, where no join resumes
/// it (a later sign-in, by anyone, would finish it as the one that signed out): its credential is
/// queued to be revoked at the hub (`to_revoke`), beside any queued before it, and only then is
/// the proposal removed. A record a stopped `complete` wrote with that same credential is revoked
/// as the record, once. A pasted join line's proposal stays: a sign-out leaves only what signing
/// in began. One that does not parse cannot be resumed either and stays as it is, and one
/// proposed on another box (`current` is this box's fingerprint) is left to
/// `set_aside_copied_pending`. The caller holds the join lock.
pub(super) fn retire_sign_in_pending_at(
    home: &Path,
    current: Option<&str>,
    accounts: &[String],
) -> Result<()> {
    let path = home.join(FILE);
    if std::fs::symlink_metadata(&path).is_err() {
        return Ok(());
    }
    let Ok(p) = crate::config::private_state_file(&path)
        .and_then(|f| Ok(serde_json::from_reader::<_, Pending>(f)?))
    else {
        return Ok(());
    };
    // A proposal copied from another box is that box's: revoking it would retire its join.
    let copied = matches!((p.host_fingerprint.as_deref(), current), (Some(made), Some(here)) if made != here);
    if copied || p.joined_by.as_deref() != Some(super::enroll::JOINED_BY_SIGN_IN) {
        return Ok(());
    }
    // Only a signing-out account's own proposal: another's, or one naming none, stays.
    if super::enroll::owner_among(p.owner.as_deref(), accounts) != super::enroll::Owner::Mine {
        return Ok(());
    }
    if load_at(home)?.is_none_or(|record| record.credential != p.credential) {
        to_revoke::queue(
            home,
            &to_revoke::Row {
                machine_id: String::new(),
                hub_origin: p.hub.clone(),
                host_fingerprint: p.host_fingerprint.clone().or_else(|| current.map(str::to_owned)),
                credential: Some(p.credential.clone()),
            },
        )?;
    }
    std::fs::remove_file(&path)?;
    sync_ancestors(home)
}

pub(super) fn pending_origin() -> Result<Option<String>> {
    Ok(read()?.map(|pending| pending.hub))
}
fn read() -> Result<Option<Pending>> {
    let path = state_dir().join(FILE);
    match std::fs::symlink_metadata(&path) {
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(_) => return Err(store_error().into()),
        Ok(_) => {}
    }
    let p: Pending = crate::config::private_state_file(&path)
        .and_then(|f| Ok(serde_json::from_reader(f)?))
        .map_err(|_| store_error())?;
    let decoded = base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(p.credential.strip_prefix("cmm_").unwrap_or_default());
    let valid = decoded.is_ok_and(|bytes| {
        bytes.len() == 32
            && format!("cmm_{}", base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(bytes))
                == p.credential
    });
    if p.version != 1
        || !valid
        || origin(Some(p.hub.clone())).ok().as_deref() != Some(&p.hub)
        || !valid_name(&p.name)
        || !matches!(p.platform.as_str(), "macos" | "linux")
    {
        return Err(store_error().into());
    }
    Ok(Some(p))
}

/// UUID temporary names, no-follow exclusive creation, checked durability.
/// The caller holds the join lock. Never truncate an existing temporary file.
#[cfg(unix)]
pub(super) fn write_durable(path: &Path, bytes: &[u8], replace: bool) -> Result<()> {
    let temp = path
        .parent()
        .ok_or_else(store_error)?
        .join(format!(".machine-join-{}.tmp", uuid::Uuid::new_v4()));
    write_with_temp(path, bytes, replace, &temp)
}

#[cfg(unix)]
fn write_with_temp(path: &Path, bytes: &[u8], replace: bool, temp: &Path) -> Result<()> {
    use std::os::unix::fs::OpenOptionsExt;
    let parent = path.parent().ok_or_else(store_error)?;
    crate::config::private_state_dir(parent)?;
    match std::fs::symlink_metadata(path) {
        Ok(_) => {
            anyhow::ensure!(replace, "pending already exists");
            crate::config::private_state_file(path)?;
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        Err(e) => return Err(e.into()),
    }
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(temp)?;
    let result = (|| {
        file.write_all(bytes)?;
        file.sync_all()?;
        // All cooperating writers hold join_lock. Revalidate the destination
        // rather than following a symlink introduced since the first check.
        match std::fs::symlink_metadata(path) {
            Ok(_) => {
                anyhow::ensure!(replace, "pending already exists");
                crate::config::private_state_file(path)?;
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => return Err(e.into()),
        }
        if replace {
            std::fs::rename(temp, path)?;
        } else {
            std::fs::hard_link(temp, path)?;
        }
        sync_ancestors(parent)?;
        Ok(())
    })();
    let _ = std::fs::remove_file(temp); // only the file this call created
    result
}
#[cfg(not(unix))]
pub(super) fn write_durable(_: &Path, _: &[u8], _: bool) -> Result<()> {
    Err(store_error().into())
}

fn valid_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 63
        && !name.chars().any(char::is_control)
        && !name.contains("cmj_")
        && !name.contains("cmm_")
}

// Sync every ancestor, including newly created custom state roots. A leaf
// directory fsync alone does not make that directory's own name durable.
pub(super) fn sync_ancestors(dir: &Path) -> Result<()> {
    sync_ancestors_with(dir, |path| {
        std::fs::File::open(path)?.sync_all()?;
        Ok(())
    })
}
fn sync_ancestors_with(dir: &Path, mut sync: impl FnMut(&Path) -> Result<()>) -> Result<()> {
    let canonical = std::fs::canonicalize(dir)?;
    for ancestor in canonical.ancestors() {
        sync(ancestor)?;
    }
    Ok(())
}

fn error(exit: i32, message: &str) -> anyhow::Error {
    crate::cli::errors::AppError::new(crate::cli::errors::Code::Runtime, "join.incomplete", message)
        .with_exit(exit)
        .into()
}
fn hub_error() -> anyhow::Error {
    error(4, "join incomplete; hub unavailable or returned an invalid response; rerun join")
}

enum Probe {
    Live(Box<MachineCredential>),
    Unknown,
    Revoked,
}
async fn probe(p: &Pending) -> Result<Probe> {
    let answer = hub_client(&p.hub, Some(&p.credential))
        .map_err(|_| hub_error())?
        .machine_redeem_self()
        .await;
    let body = match answer {
        Ok(body) => body.into_inner(),
        Err(error) => {
            let error = cmux_cloud_client::ApiError::from_api(error).await;
            return match (error.status, error.code.as_deref()) {
                (Some(401), Some("machine.unknown")) => Ok(Probe::Unknown),
                (Some(401), Some("machine.revoked")) => Ok(Probe::Revoked),
                _ => Err(hub_error()),
            };
        }
    };
    let id = |value: &str| -> Result<String> {
        Some(value)
            .filter(|s| {
                !s.is_empty()
                    && !s.contains("cmj_")
                    && !s.contains("cmm_")
                    && !s.chars().any(char::is_control)
            })
            .map(str::to_owned)
            .ok_or_else(hub_error)
    };
    let machine_id = id(&body.machine_id)?;
    let team_id = id(&body.team_id)?;
    let name = id(&body.name)?;
    let generation =
        u64::try_from(body.credential_generation).ok().filter(|n| *n > 0).ok_or_else(hub_error)?;
    if body.wg_public_key != p.wg_public_key
        || body.platform != p.platform
        || body.hostname != p.hostname
        || name != p.name
        || body.join_token_id.is_empty()
        || body.expires_at.is_empty()
    {
        return Err(hub_error());
    }
    if let Some(old) = &p.prior
        && (old.machine_id != machine_id
            || old.team_id != team_id
            || generation <= old.credential_generation)
    {
        return Err(hub_error());
    }
    Ok(Probe::Live(Box::new(MachineCredential {
        credential: p.credential.clone(),
        machine_id,
        team_id,
        name,
        hub_origin: p.hub.clone(),
        last_heartbeat: None,
        revoked: false,
        wg_public_key: p.wg_public_key.clone(),
        credential_generation: generation,
        // Optional until every hub names it: a missing or malformed one only means no
        // automatic same-person control, never a failed join.
        user_id: body.user_id.as_ref().and_then(|user| safe_id(&user.to_string())),
        // Joined on this box: a later start on another box finds the copy.
        host_fingerprint: host_fingerprint::current(),
        cloned: false,
        // `complete` sets what joined it and what it said it can do.
        joined_by: None,
        capabilities: None,
    })))
}

/// The record a probed join stores: what began it, whose it is, and what its redeem said it can
/// do come from the proposal, never from whoever finishes it. A sign-in's join is recorded under
/// the account that minted it; the hub's `userId`, when it names one, only has to agree. A
/// sign-in's join with no account is recorded under none (never under the hub's alone).
fn completed_record(p: &Pending, probed: &MachineCredential) -> Result<MachineCredential> {
    let sign_in = p.joined_by.as_deref() == Some(super::enroll::JOINED_BY_SIGN_IN);
    let user_id = if sign_in {
        if let (Some(owner), Some(redeemed)) = (p.owner.as_deref(), probed.user_id.as_deref())
            && owner != redeemed
        {
            return Err(error(3, "the hub joined this machine for another account"));
        }
        p.owner.clone()
    } else {
        probed.user_id.clone()
    };
    Ok(MachineCredential {
        joined_by: p.joined_by.clone(),
        capabilities: p.capabilities.clone(),
        user_id,
        ..probed.clone()
    })
}

fn complete(p: &Pending, record: &MachineCredential, report: Report) -> Result<()> {
    let record = &completed_record(p, record)?;
    authority().and_then(|a| a.enroll()).map_err(|_| store_error())?;
    let bytes = Zeroizing::new(serde_json::to_vec(record).map_err(|_| store_error())?);
    write_durable(&credential_path(), &bytes, true).map_err(|_| store_error())?;
    let sign_in = p.joined_by.as_deref() == Some(super::enroll::JOINED_BY_SIGN_IN);
    relay_for_join_at(&crate::config::Config::path(), &p.hub, sign_in)
        .map_err(|_| store_error())?;
    // Remove the immutable recovery proof only after final + relay are durable.
    crate::config::private_state_file(&state_dir().join(FILE)).map_err(|_| store_error())?;
    std::fs::remove_file(state_dir().join(FILE)).map_err(|_| store_error())?;
    // A join made here ends what this hub's revoke kept from enrolling on its own.
    to_revoke::clear_revoked(&state_dir(), &p.hub);
    sync_ancestors(&state_dir()).map_err(|_| store_error())?;
    match report {
        Report::Quiet => {}
        Report::Json => {
            warn_existing_helpers();
            crate::cli::output::print_json(
                &json!({"joined":true,"alreadyJoined":false,"machineId":record.machine_id,"teamId":record.team_id,"name":record.name,"hubOrigin":record.hub_origin}),
            );
        }
        Report::Text => {
            warn_existing_helpers();
            println!("joined {} ({})", record.name, record.machine_id);
        }
    }
    Ok(())
}

/// The local revocation bit may lag the hub. Resolve before using a final
/// credential as replacement proof; unknown/expired credentials cannot prove
/// replacement either. The server still refuses any active key without proof.
async fn replacement_proof(mut old: MachineCredential) -> Result<Option<MachineCredential>> {
    let hub = origin(Some(old.hub_origin.clone())).map_err(|_| store_error())?;
    let answer = hub_client(&hub, Some(&old.credential))
        .map_err(|_| hub_error())?
        .machine_redeem_self()
        .await;
    let body = match answer {
        Ok(body) => body.into_inner(),
        Err(error) => {
            let error = cmux_cloud_client::ApiError::from_api(error).await;
            if error.status == Some(401)
                && matches!(error.code.as_deref(), Some("machine.revoked" | "machine.unknown"))
            {
                return Ok(None);
            }
            return Err(hub_error());
        }
    };
    if *body.machine_id != old.machine_id
        || *body.team_id != old.team_id
        || body.wg_public_key != old.wg_public_key
    {
        return Err(hub_error());
    }
    old.credential_generation = u64::try_from(body.credential_generation)
        .ok()
        .filter(|n| *n > 0 && *n >= old.credential_generation)
        .ok_or_else(hub_error)?;
    Ok(Some(old))
}

fn new_pending(
    hub: String,
    name: String,
    prior: Option<MachineCredential>,
    overwrite: bool,
    joined_by: Option<String>,
    owner: Option<String>,
) -> Result<Pending> {
    let mut random = Zeroizing::new([0u8; 32]);
    getrandom::fill(&mut *random).map_err(|_| store_error())?;
    let p = Pending {
        version: 1,
        credential: format!(
            "cmm_{}",
            base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(*random)
        ),
        hub,
        name,
        hostname: crate::pairing::machine_name(),
        platform: if cfg!(target_os = "macos") { "macos" } else { "linux" }.to_owned(),
        wg_public_key: leave::node_key_for_join_at(&state_dir())
            .map_err(|_| store_error())?
            .public_key_b64(),
        prior,
        host_fingerprint: host_fingerprint::current(),
        joined_by,
        capabilities: Some(machine_capabilities()),
        owner,
    };
    let bytes = Zeroizing::new(serde_json::to_vec(&p).map_err(|_| store_error())?);
    write_durable(&state_dir().join(FILE), &bytes, overwrite).map_err(|_| store_error())?;
    Ok(p)
}

pub(super) async fn join(
    hub: Option<String>,
    name: Option<String>,
    replace: bool,
    report: Report,
    token: Option<String>,
    began: Option<Began<'_>>,
) -> Result<()> {
    if set_aside_copied_pending(host_fingerprint::current().as_deref())? && report != Report::Quiet
    {
        eprintln!(
            "a join begun on another machine was set aside; this join makes this machine's own"
        );
    }
    let existing = read()?;
    let mut pending = if let Some(p) = existing {
        // Retry a failed directory fsync before any request can redeem this
        // proof. Reading a surviving directory entry alone is not durability.
        crate::config::private_state_file(&state_dir().join(FILE))
            .and_then(|f| {
                f.sync_all()?;
                Ok(())
            })
            .map_err(|_| store_error())?;
        sync_ancestors(&state_dir()).map_err(|_| store_error())?;
        if hub.as_ref().is_some_and(|h| origin(Some(h.clone())).ok().as_deref() != Some(&p.hub))
            || name.as_ref().is_some_and(|n| n != &p.name)
        {
            return Err(error(2, "join incomplete; retry with the original hub and name"));
        }
        match probe(&p).await? {
            // Completes as what began it (`Pending::joined_by`), whatever resumes it.
            Probe::Live(record) => return complete(&p, &record, report),
            Probe::Revoked if replace && token.is_some() => {
                // Definitive revocation makes the proposal unusable. Only an
                // explicit replacement with fresh stdin may replace this proof.
                // If this was a replacement, its old final is already retired.
                new_pending(p.hub, p.name, None, true, p.joined_by, p.owner)?
            }
            Probe::Revoked => return Err(error(3, "revoked: run machine add again")),
            Probe::Unknown => p,
        }
    } else {
        // A home copied from another box: mark it and give this box its own node key before
        // anything proposes one (the caller holds the join lock).
        settle_clone_at(&state_dir(), host_fingerprint::current().as_deref())
            .map_err(|_| store_error())?;
        if already_joined(replace, report)? {
            return Ok(());
        }
        if token.is_none() {
            return Err(error(2, "join token must be provided on stdin"));
        }
        let hub = origin(hub).map_err(|_| error(2, "hub origin is malformed"))?;
        let name = local_name(name);
        if !valid_name(&name) {
            return Err(error(2, "machine name is malformed"));
        }
        let prior = if replace {
            match load().map_err(|_| store_error())? {
                // A copy never proves a replacement with the original box's credential: that
                // would retire the original's enrollment from here.
                Some(old)
                    if !copied_here(&state_dir(), &old, host_fingerprint::current().as_deref()) =>
                {
                    replacement_proof(old).await?
                }
                _ => None,
            }
        } else {
            None
        };
        if prior.as_ref().is_some_and(|old| old.hub_origin != hub) {
            return Err(error(3, "existing enrollment cannot authorize replacement"));
        }
        new_pending(
            hub,
            name,
            prior,
            false,
            began.as_ref().map(|began| began.joined_by.to_owned()),
            began.map(|began| began.owner.to_owned()),
        )?
    };
    // An older build's proposal sent no list; the redeem now does, and the record says so.
    pending.capabilities.get_or_insert_with(machine_capabilities);
    let token =
        token.ok_or_else(|| error(2, "join incomplete; original join token required on stdin"))?;
    authority().and_then(|a| a.enroll()).map_err(|_| store_error())?;
    let mut body = json!({"token":token,"proposedCredential":pending.credential,
        "name":pending.name,"hostname":pending.hostname,"platform":pending.platform,"wgPublicKey":pending.wg_public_key,
        "capabilities":pending.capabilities});
    if let Some(old) = &pending.prior {
        body.set("replaceCredential", json!(old.credential));
    }
    let refused = || {
        error(
            3,
            "join incomplete; enrollment refused; rerun with the original token or obtain fresh enrollment",
        )
    };
    // The spec's own limits (name and hostname length) are checked here as
    // the hub would: a body it would refuse is never sent. The generated type
    // keeps `platform` a string; the pending record's check (macos or linux)
    // already holds it to the spec's two values.
    let body: cmux_cloud_client::types::JoinRedeem =
        serde_json::from_value(body).map_err(|_| refused())?;
    let answer =
        hub_client(&pending.hub, None).map_err(|_| hub_error())?.machine_redeem_redeem(&body).await;
    if let Err(e) = answer {
        let e = cmux_cloud_client::ApiError::from_api(e).await;
        return Err(match e.status {
            Some(400 | 401 | 404 | 409 | 410) => refused(),
            _ => error(
                4,
                "join incomplete; enrollment refused; rerun with the original token or obtain fresh enrollment",
            ),
        });
    }
    match probe(&pending).await? {
        Probe::Live(record) => complete(&pending, &record, report),
        Probe::Revoked => Err(error(3, "revoked: run machine add again")),
        Probe::Unknown => Err(hub_error()),
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::os::unix::fs::{PermissionsExt, symlink};

    fn pending(joined_by: Option<&str>, capabilities: Option<Vec<String>>) -> Pending {
        Pending {
            version: 1,
            credential: "cmm_x".into(),
            hub: "https://hub.example".into(),
            name: "box".into(),
            hostname: "box".into(),
            platform: "linux".into(),
            wg_public_key: "key".into(),
            prior: None,
            host_fingerprint: None,
            joined_by: joined_by.map(str::to_owned),
            capabilities,
            owner: joined_by.map(|_| "user_me".to_owned()),
        }
    }

    #[test]
    fn a_join_completes_as_what_began_it_whoever_resumes_it() {
        // A sign-in's redeem landed, its probe failed: the proposal stays on disk and says so.
        let begun =
            pending(Some(super::super::enroll::JOINED_BY_SIGN_IN), Some(machine_capabilities()));
        let on_disk = serde_json::to_vec(&begun).unwrap();
        let resumed: Pending = serde_json::from_slice(&on_disk).unwrap();
        let probed = MachineCredential { credential: "cmm_x".into(), ..Default::default() };
        let record = completed_record(&resumed, &probed).unwrap();
        assert_eq!(record.joined_by.as_deref(), Some("sign-in"), "a sign-out then leaves it");
        assert_eq!(record.capabilities, Some(vec!["vault.proxy.v1".to_owned()]));
        // A pasted join line's stays the person's, even when a sign-in finishes it.
        let pasted = completed_record(&pending(None, Some(Vec::new())), &probed).unwrap();
        assert_eq!(pasted.joined_by, None);
        // An older build's proposal: no provenance, no list (the next sign-in rotates once).
        let older: Pending = serde_json::from_value(
            json!({"version":1,"credential":"cmm_x","hub":"https://hub.example","name":"box",
                "hostname":"box","platform":"linux","wg_public_key":"key","prior":null}),
        )
        .unwrap();
        let record = completed_record(&older, &probed).unwrap();
        assert_eq!((record.joined_by, record.capabilities), (None, None));
    }

    #[test]
    fn a_sign_in_join_with_no_redeemed_user_records_the_minting_account() {
        let begun = pending(Some(super::super::enroll::JOINED_BY_SIGN_IN), None);
        // The hub's redeem named no account: the minting account is recorded.
        let probed = MachineCredential { credential: "cmm_x".into(), ..Default::default() };
        let record = completed_record(&begun, &probed).unwrap();
        assert_eq!(record.user_id.as_deref(), Some("user_me"));
        // The hub named the same account: recorded once, the same.
        let same = MachineCredential { user_id: Some("user_me".into()), ..probed.clone() };
        assert_eq!(completed_record(&begun, &same).unwrap().user_id.as_deref(), Some("user_me"));
        // The hub named another: nothing is recorded.
        let other = MachineCredential { user_id: Some("user_b".into()), ..probed.clone() };
        assert!(completed_record(&begun, &other).is_err());
        // A sign-in's proposal from before owners were kept: no account, never the hub's alone.
        let older = Pending { owner: None, ..pending(Some("sign-in"), None) };
        assert_eq!(completed_record(&older, &other).unwrap().user_id, None);
        // A pasted join line's: what the hub says, as before.
        let pasted = pending(None, None);
        assert_eq!(completed_record(&pasted, &other).unwrap().user_id.as_deref(), Some("user_b"));
    }

    #[test]
    fn custom_state_ancestors_are_synced_and_errors_stop_the_commit() {
        let dir = tempfile::tempdir().unwrap();
        let state = dir.path().join("new/config/state");
        std::fs::create_dir_all(&state).unwrap();
        let canonical = std::fs::canonicalize(&state).unwrap();
        let mut seen = Vec::new();
        sync_ancestors_with(&state, |path| {
            seen.push(path.to_owned());
            Ok(())
        })
        .unwrap();
        assert_eq!(seen, canonical.ancestors().map(Path::to_owned).collect::<Vec<_>>());
        let mut count = 0;
        assert!(
            sync_ancestors_with(&state, |_| {
                count += 1;
                anyhow::ensure!(count < 3, "injected ancestor sync failure");
                Ok(())
            })
            .is_err()
        );
        assert_eq!(count, 3);
    }

    #[test]
    fn durable_pending_is_private_immutable_and_cannot_follow_links() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("pending");
        write_durable(&path, b"first", false).unwrap();
        assert_eq!(std::fs::metadata(&path).unwrap().permissions().mode() & 0o777, 0o600);
        assert!(write_durable(&path, b"second", false).is_err());
        assert_eq!(std::fs::read(&path).unwrap(), b"first");
        let link = dir.path().join("link");
        symlink(&path, &link).unwrap();
        assert!(write_durable(&link, b"second", true).is_err());
        assert_eq!(std::fs::read(&path).unwrap(), b"first");
        write_durable(&path, b"second", true).unwrap();
        assert_eq!(std::fs::read(&path).unwrap(), b"second");
    }

    #[test]
    fn colliding_temporary_file_is_neither_truncated_nor_deleted() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("final");
        let temp = dir.path().join("temp");
        std::fs::write(&temp, b"owned by another invocation").unwrap();
        assert!(write_with_temp(&path, b"secret", true, &temp).is_err());
        assert_eq!(std::fs::read(&temp).unwrap(), b"owned by another invocation");
        assert!(!path.exists());
        let link = dir.path().join("link");
        symlink(&temp, &link).unwrap();
        assert!(write_with_temp(&path, b"secret", true, &link).is_err());
        assert!(std::fs::symlink_metadata(link).unwrap().is_symlink());
        assert_eq!(std::fs::read(&temp).unwrap(), b"owned by another invocation");
    }
}
