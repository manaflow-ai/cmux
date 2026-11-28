use anyhow::{Result, anyhow};
use std::os::unix::fs::{DirBuilderExt, symlink};
use std::path::{Path, PathBuf};
use tokio::process::Command;

/// Grok's saved login and per-model credentials outrank XAI_API_KEY. Use a fresh
/// home and share only native session history and the user's requirements.
pub(super) fn isolate(
    cmd: &mut Command,
    cwd: &Path,
    session: Option<&str>,
    remote: bool,
) -> Result<Option<tempfile::TempDir>> {
    let env = super::command_env_with(cmd, !remote);
    let path = |key: &str| {
        env.iter().find(|(name, value)| name == key && !value.is_empty()).map(|(_, value)| {
            let path = PathBuf::from(value);
            if path.is_absolute() { path } else { cwd.join(path) }
        })
    };
    let native_home = path("GROK_HOME")
        .or_else(|| path("HOME").or_else(dirs::home_dir).map(|home| home.join(".grok")));
    // A managed home can require its signed policy and deployment credential together.
    // Moving the launch out of that home would bypass those requirements.
    let unavailable = || anyhow!("This Grok connection cannot launch the native runner");
    if env.iter().any(|(key, value)| key == "GROK_DEPLOYMENT_KEY" && !value.is_empty()) {
        return Err(unavailable());
    }
    if let Some(native_home) = &native_home {
        for name in ["managed_config.sig.json", "managed_identity.sig.json"] {
            if native_home.join(name).try_exists()? {
                return Err(unavailable());
            }
        }
    }
    let mut builder = tempfile::Builder::new();
    builder.prefix("grok-key-");
    let home = if let Some(id) = session {
        let dir = crate::agent::session_tmp::make(
            &crate::agent::session_tmp::per_user_base(),
            &crate::config::home(),
            id,
        )
        .ok_or_else(unavailable)?;
        builder.tempdir_in(dir)?
    } else {
        builder.tempdir()?
    };
    if let Some(native_home) = native_home {
        if session.is_some() {
            let sessions = native_home.join("sessions");
            std::fs::DirBuilder::new().recursive(true).mode(0o700).create(&sessions)?;
            symlink(&sessions, home.path().join("sessions"))?;
        }
        let requirements = native_home.join("requirements.toml");
        if requirements.try_exists()? {
            symlink(&requirements, home.path().join("requirements.toml"))?;
        }
    }
    for name in [
        "GROK_AUTH",
        "GROK_AUTH_PATH",
        "GROK_AUTH_PROVIDER_COMMAND",
        "GROK_CLI_CHAT_PROXY_BASE_URL",
        "GROK_CODE_XAI_API_KEY",
        "GROK_CONFIG",
        "GROK_CONFIG_PATH",
    ] {
        cmd.env_remove(name);
    }
    cmd.env("GROK_HOME", home.path());
    if session.is_some() {
        // A durable host can outlive this process. The session folder owns its cleanup.
        home.keep();
        Ok(None)
    } else {
        Ok(Some(home))
    }
}
