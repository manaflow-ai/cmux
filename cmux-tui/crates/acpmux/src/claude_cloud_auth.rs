//! Claude's model-plane pair on a cmux Cloud machine, for the launches acpmux makes itself.
//!
//! A login shell on the image (`agent-config.sh`, `cmux_claude_set_team_env_aside`) keeps the
//! model plane's `ANTHROPIC_BASE_URL` / `ANTHROPIC_API_KEY` out of the shell, under
//! `CMUX_CLAUDE_TEAM_*`, so the pair never outranks a person's own Claude sign-in. The image's
//! launcher (`/etc/cmux/claude`, `agent-auth.sh` `cmux_claude_apply_auth_mode`) puts it back in team
//! mode. acpmux starts Claude itself, and its login-env import keeps no `CMUX_` name, so a Claude
//! with no sign-in got neither and answered "Not logged in · Please run /login", through the
//! inference gateway too (gateway E2E on development and production, 2026-11-10).
//!
//! [`team_pair`] is that rule for an owner machine with that script (`codex_cloud_auth` has the
//! same one for Codex): `CMUX_CLAUDE_AUTH=own|team` pins it, then `cr use`'s recorded choice; a
//! sign-in of its own (`~/.claude/.credentials.json`, or a key or token the person set) keeps own;
//! no `https://` team origin, or one that does not resolve, keeps own. Otherwise team: the pair the
//! shell set aside, read from the model-plane env file it was persisted to, or the origin and the
//! public placeholder. A pair the person set themselves stays.

use crate::codex_cloud_auth::{Inputs, PLACEHOLDER_KEY};

/// The variables a person's own Claude sign-in can come from (`claude_auth.rs`).
const OWN_KEYS: [&str; 3] =
    ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN"];

/// The model-plane pair to add to a Claude launch in team mode, or None (own mode, a pair already
/// set, or not an owner Cloud image). `resolves` answers whether the team origin's host resolves.
pub async fn team_pair<F, Fut>(inputs: &Inputs<'_>, resolves: F) -> Option<[(String, String); 2]>
where
    F: FnOnce(String) -> Fut,
    Fut: std::future::Future<Output = bool>,
{
    if !inputs.owner_cloud_image() {
        return None;
    }
    let var = |k: &str| (inputs.var)(k).filter(|v| !v.is_empty());
    // A pair in the launch already (the person's, or a route's) wins, as in the launcher.
    if var("ANTHROPIC_BASE_URL").is_some() || var("ANTHROPIC_API_KEY").is_some() {
        return None;
    }
    let pinned = match var("CMUX_CLAUDE_AUTH").as_deref().map(str::trim) {
        Some("own") => return None,
        Some("team") => true,
        _ => false,
    };
    if !pinned {
        match inputs.choice_for("claude") {
            Some("own") => return None,
            Some(_) => {}
            None => {
                let store = var("CLAUDE_CONFIG_DIR")
                    .map(std::path::PathBuf::from)
                    .unwrap_or_else(|| inputs.home.join(".claude"));
                if OWN_KEYS.iter().any(|k| var(k).is_some())
                    || crate::agent_login::signed_in_at(crate::agent_login::Agent::Claude, &store)
                {
                    return None;
                }
            }
        }
    }
    let origin = inputs.team_origin()?;
    let host = origin.trim_start_matches("https://").split(['/', '?', '#']).next()?.to_owned();
    if host.is_empty() || !resolves(host).await {
        return None;
    }
    let base = inputs.model_plane_var("ANTHROPIC_BASE_URL").unwrap_or_else(|| origin.clone());
    let key =
        inputs.model_plane_var("ANTHROPIC_API_KEY").unwrap_or_else(|| PLACEHOLDER_KEY.to_owned());
    Some([("ANTHROPIC_BASE_URL".to_owned(), base), ("ANTHROPIC_API_KEY".to_owned(), key)])
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeMap;
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicU32, Ordering};

    struct Machine {
        root: PathBuf,
        home: PathBuf,
    }

    impl Drop for Machine {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.root);
        }
    }

    fn machine(kind: &str) -> Machine {
        static N: AtomicU32 = AtomicU32::new(0);
        let n = N.fetch_add(1, Ordering::SeqCst);
        let root = std::env::temp_dir()
            .join(format!("acpmux-claude-cloud-auth-{}-{n}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(root.join("etc/cmux")).unwrap();
        std::fs::write(root.join("etc/cmux/vm-kind"), format!("{kind}\n")).unwrap();
        std::fs::write(root.join("etc/cmux/agent-auth.sh"), "# image\n").unwrap();
        std::fs::write(
            root.join("etc/cmux/model-plane.env"),
            "export CMUX_CODEROUTER_URL='https://coderouter.cmux.internal'\n\
             export ANTHROPIC_BASE_URL='https://coderouter.cmux.internal'\n\
             export ANTHROPIC_API_KEY='cmux-vm-edge-placeholder'\n",
        )
        .unwrap();
        let home = root.join("home");
        std::fs::create_dir_all(home.join(".claude")).unwrap();
        Machine { root, home }
    }

    fn vars(pairs: &[(&str, &str)]) -> Box<dyn Fn(&str) -> Option<String> + Sync> {
        let map: BTreeMap<String, String> =
            pairs.iter().map(|(k, v)| ((*k).to_owned(), (*v).to_owned())).collect();
        Box::new(move |k: &str| map.get(k).cloned())
    }

    async fn pair(m: &Machine, var: &[(&str, &str)], dns: bool) -> Option<[(String, String); 2]> {
        let var = vars(var);
        let inputs = Inputs { root: &m.root, home: &m.home, var: &*var, broker: false };
        team_pair(&inputs, |_| async move { dns }).await
    }

    #[tokio::test]
    async fn a_claude_with_no_sign_in_gets_the_model_plane_pair() {
        let m = machine("owner");
        let got = pair(&m, &[], true).await.expect("team");
        assert_eq!(
            got[0],
            ("ANTHROPIC_BASE_URL".to_owned(), "https://coderouter.cmux.internal".to_owned())
        );
        assert_eq!(got[1], ("ANTHROPIC_API_KEY".to_owned(), PLACEHOLDER_KEY.to_owned()));
        // The origin does not resolve: team mode could not work, so Claude shows its own sign-in.
        assert_eq!(pair(&m, &[], false).await, None);
    }

    #[tokio::test]
    async fn a_sign_in_a_choice_or_a_persons_pair_keeps_own() {
        let m = machine("owner");
        assert_eq!(pair(&m, &[("ANTHROPIC_API_KEY", "sk-own")], true).await, None);
        assert_eq!(
            pair(&m, &[("ANTHROPIC_BASE_URL", "https://api.example.test")], true).await,
            None
        );
        assert_eq!(pair(&m, &[("CLAUDE_CODE_OAUTH_TOKEN", "t")], true).await, None);
        assert_eq!(pair(&m, &[("CMUX_CLAUDE_AUTH", "own")], true).await, None);
        let dir = m.home.join(".config/cmux/agent-auth");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("claude"), "own\n").unwrap();
        assert_eq!(pair(&m, &[], true).await, None);
        // `cr use team` over a sign-in of its own: team.
        std::fs::write(dir.join("claude"), "team\n").unwrap();
        std::fs::write(m.home.join(".claude/.credentials.json"), r#"{"claudeAiOauth":{"a":1}}"#)
            .unwrap();
        assert!(pair(&m, &[], true).await.is_some());
        // No choice: the sign-in keeps own.
        std::fs::remove_file(dir.join("claude")).unwrap();
        assert_eq!(pair(&m, &[], true).await, None);
        // The env pin wins over it.
        assert!(pair(&m, &[("CMUX_CLAUDE_AUTH", "team")], true).await.is_some());
    }

    #[tokio::test]
    async fn only_an_owner_cloud_image_with_a_team_plane() {
        assert_eq!(pair(&machine("team"), &[], true).await, None);
        let m = machine("owner");
        std::fs::write(
            m.root.join("etc/cmux/model-plane.env"),
            "export OPENAI_BASE_URL='https://x/v1'\n",
        )
        .unwrap();
        assert_eq!(pair(&m, &[], true).await, None);
    }
}
