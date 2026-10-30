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
fn sync_ancestors(dir: &Path) -> Result<()> {
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
    Live(MachineCredential),
    Unknown,
    Revoked,
}
async fn probe(p: &Pending) -> Result<Probe> {
    let response = http_client()
        .map_err(|_| hub_error())?
        .get(format!("{}/v1/machines/credentials/self", p.hub))
        .bearer_auth(&p.credential)
        .send()
        .await
        .map_err(|_| hub_error())?;
    let status = response.status();
    let body: Value = response.json().await.map_err(|_| hub_error())?;
    if status.as_u16() == 401 {
        return match body["code"].as_str() {
            Some("machine.unknown") => Ok(Probe::Unknown),
            Some("machine.revoked") => Ok(Probe::Revoked),
            _ => Err(hub_error()),
        };
    }
    if !status.is_success() {
        return Err(hub_error());
    }
    let id = |key: &str| -> Result<String> {
        let value = body[key]
            .as_str()
            .filter(|s| {
                !s.is_empty()
                    && !s.contains("cmj_")
                    && !s.contains("cmm_")
                    && !s.chars().any(char::is_control)
            })
            .ok_or_else(hub_error)?;
        Ok(value.to_owned())
    };
    let machine_id = id("machineId")?;
    let team_id = id("teamId")?;
    let name = id("name")?;
    let generation =
        body["credentialGeneration"].as_u64().filter(|n| *n > 0).ok_or_else(hub_error)?;
    if body["wgPublicKey"] != p.wg_public_key
        || body["platform"] != p.platform
        || body["hostname"] != p.hostname
        || name != p.name
        || body["joinTokenId"].as_str().is_none_or(str::is_empty)
        || body["expiresAt"].as_str().is_none_or(str::is_empty)
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
    Ok(Probe::Live(MachineCredential {
        credential: p.credential.clone(),
        machine_id,
        team_id,
        name,
        hub_origin: p.hub.clone(),
        last_heartbeat: None,
        revoked: false,
        wg_public_key: p.wg_public_key.clone(),
        credential_generation: generation,
    }))
}

fn complete(p: &Pending, record: &MachineCredential, json_out: bool) -> Result<()> {
    authority().and_then(|a| a.enroll()).map_err(|_| store_error())?;
    let bytes = Zeroizing::new(serde_json::to_vec(record).map_err(|_| store_error())?);
    write_durable(&credential_path(), &bytes, true).map_err(|_| store_error())?;
    configure_mesh_relay(&p.hub).map_err(|_| store_error())?;
    // Remove the immutable recovery proof only after final + relay are durable.
    crate::config::private_state_file(&state_dir().join(FILE)).map_err(|_| store_error())?;
    std::fs::remove_file(state_dir().join(FILE)).map_err(|_| store_error())?;
    sync_ancestors(&state_dir()).map_err(|_| store_error())?;
    warn_existing_helpers();
    if json_out {
        crate::cli::output::print_json(
            &json!({"joined":true,"alreadyJoined":false,"machineId":record.machine_id,"teamId":record.team_id,"name":record.name,"hubOrigin":record.hub_origin}),
        );
    } else {
        println!("joined {} ({})", record.name, record.machine_id);
    }
    Ok(())
}

/// The local revocation bit may lag the hub. Resolve before using a final
/// credential as replacement proof; unknown/expired credentials cannot prove
/// replacement either. The server still refuses any active key without proof.
async fn replacement_proof(mut old: MachineCredential) -> Result<Option<MachineCredential>> {
    let hub = origin(Some(old.hub_origin.clone())).map_err(|_| store_error())?;
    let response = http_client()
        .map_err(|_| hub_error())?
        .get(format!("{hub}/v1/machines/credentials/self"))
        .bearer_auth(&old.credential)
        .send()
        .await
        .map_err(|_| hub_error())?;
    let status = response.status();
    let body: Value = response.json().await.map_err(|_| hub_error())?;
    if status.as_u16() == 401
        && matches!(body["code"].as_str(), Some("machine.revoked" | "machine.unknown"))
    {
        return Ok(None);
    }
    if !status.is_success()
        || body["machineId"] != old.machine_id
        || body["teamId"] != old.team_id
        || body["wgPublicKey"] != old.wg_public_key
    {
        return Err(hub_error());
    }
    old.credential_generation = body["credentialGeneration"]
        .as_u64()
        .filter(|n| *n > 0 && *n >= old.credential_generation)
        .ok_or_else(hub_error)?;
    Ok(Some(old))
}

fn new_pending(
    hub: String,
    name: String,
    prior: Option<MachineCredential>,
    overwrite: bool,
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
        wg_public_key: crate::cli::mesh_node_key::load_or_create()
            .map_err(|_| store_error())?
            .public_key_b64(),
        prior,
    };
    let bytes = Zeroizing::new(serde_json::to_vec(&p).map_err(|_| store_error())?);
    write_durable(&state_dir().join(FILE), &bytes, overwrite).map_err(|_| store_error())?;
    Ok(p)
}

pub(super) async fn join(
    hub: Option<String>,
    name: Option<String>,
    replace: bool,
    json_out: bool,
    token: Option<String>,
) -> Result<()> {
    let existing = read()?;
    let pending = if let Some(p) = existing {
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
            Probe::Live(record) => return complete(&p, &record, json_out),
            Probe::Revoked if replace && token.is_some() => {
                // Definitive revocation makes the proposal unusable. Only an
                // explicit replacement with fresh stdin may replace this proof.
                // If this was a replacement, its old final is already retired.
                new_pending(p.hub, p.name, None, true)?
            }
            Probe::Revoked => return Err(error(3, "revoked: run machine add again")),
            Probe::Unknown => p,
        }
    } else {
        if already_joined(replace, json_out)? {
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
                Some(old) => replacement_proof(old).await?,
                None => None,
            }
        } else {
            None
        };
        if prior.as_ref().is_some_and(|old| old.hub_origin != hub) {
            return Err(error(3, "existing enrollment cannot authorize replacement"));
        }
        new_pending(hub, name, prior, false)?
    };
    let token =
        token.ok_or_else(|| error(2, "join incomplete; original join token required on stdin"))?;
    authority().and_then(|a| a.enroll()).map_err(|_| store_error())?;
    let mut body = json!({"token":token,"proposedCredential":pending.credential,
        "name":pending.name,"hostname":pending.hostname,"platform":pending.platform,"wgPublicKey":pending.wg_public_key});
    if let Some(old) = &pending.prior {
        body.set("replaceCredential", json!(old.credential));
    }
    let response = http_client()
        .map_err(|_| hub_error())?
        .post(format!("{}/v1/machines/join-tokens/redeem", pending.hub))
        .json(&body)
        .send()
        .await
        .map_err(|_| hub_error())?;
    if !response.status().is_success() {
        let status = response.status().as_u16();
        return Err(error(
            if matches!(status, 400 | 401 | 404 | 409 | 410) { 3 } else { 4 },
            "join incomplete; enrollment refused; rerun with the original token or obtain fresh enrollment",
        ));
    }
    match probe(&pending).await? {
        Probe::Live(record) => complete(&pending, &record, json_out),
        Probe::Revoked => Err(error(3, "revoked: run machine add again")),
        Probe::Unknown => Err(hub_error()),
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::os::unix::fs::{PermissionsExt, symlink};

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
