//! Agent keys for cloud subagents (workers/cmux-vm README, "Agent keys and
//! client sessions"): each cloud subagent gets its own short-lived cmux VM key
//! that reaches only the sandboxes it creates (label `cmux.agent=<key id>`),
//! within a VM count and USD/h budget. The team's provider key never leaves
//! the cmux VM service.
//!
//! The Chief issues the key with the issuer credential in
//! `~/.config/cmux/agent-issuer.json` (mode 0600; a cmux VM API key with
//! `vm:write`), the pool tool writes it on the VM as
//! `~/.config/cmux/agents/<id>.json` (mode 0600), and the subagent's task names
//! that file. The key never enters a prompt, the chat or a log. The Chief
//! revokes it once the subagent has been done for a while; the service then
//! deletes the agent's VMs. A key that expires (TTL) is cleaned up by the
//! service's reaper on its own.

use std::path::{Path, PathBuf};
use std::time::Duration;

use serde_json::{Value, json};

/// The issuer file under the home directory.
pub const ISSUER_FILE: &str = ".config/cmux/agent-issuer.json";

/// How long a subagent stays done before its key is revoked (a follow-up
/// `tell` within it keeps its sandboxes).
pub const REVOKE_AFTER_DONE: Duration = Duration::from_secs(30 * 60);

/// One issued agent key: its public id and the file the agent reads.
#[derive(Clone, Debug, PartialEq)]
pub struct AgentKey {
    /// `vmk_...`, public (audit rows, revoke).
    pub id: String,
    /// The JSON the pool tool writes to the VM: holds the secret key.
    pub file: String,
}

/// Issues and revokes agent keys.
pub trait AgentKeys: Send + Sync {
    /// A new key for subagent `agent` (`a12`).
    fn issue(&self, agent: &str) -> Result<AgentKey, String>;
    /// Revokes the key (and so deletes its VMs); an unknown key is not an error.
    fn revoke(&self, key_id: &str) -> Result<(), String>;
}

/// The issuer credential and the budget each agent key gets.
#[derive(Clone, Debug, PartialEq)]
pub struct Issuer {
    api_url: String,
    key: String,
    /// `X-Cmux-Team-Id`, needed only for a service key.
    team: Option<String>,
    ttl_seconds: u64,
    max_vms: u32,
    max_usd_per_hour: f64,
}

impl Issuer {
    /// The issuer at `home`/ISSUER_FILE; Ok(None) when there is none (agent
    /// keys off). A file other users can read is refused.
    pub fn load(home: &Path) -> Result<Option<Issuer>, String> {
        let path = home.join(ISSUER_FILE);
        let Ok(text) = std::fs::read_to_string(&path) else {
            return Ok(None);
        };
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = std::fs::metadata(&path)
                .map_err(|e| format!("{}: {e}", path.display()))?
                .permissions()
                .mode();
            if mode & 0o077 != 0 {
                return Err(format!(
                    "{} must be mode 0600 (it is {:o}); agent keys stay off",
                    path.display(),
                    mode & 0o777
                ));
            }
        }
        Issuer::parse(&text)
            .map(Some)
            .map_err(|e| format!("{}: {e}", path.display()))
    }

    /// The issuer from the file's JSON: `key` and `apiUrl`, optional `teamId`,
    /// `ttlSeconds` (default 14400), `maxVms` (5), `maxUsdPerHour` (2).
    pub fn parse(text: &str) -> Result<Issuer, String> {
        let v: Value = serde_json::from_str(text).map_err(|e| format!("not JSON: {e}"))?;
        let key = v["key"].as_str().unwrap_or_default().to_owned();
        if !key.starts_with("cmuxvm_sk_") {
            return Err("key must be a cmux VM API key (cmuxvm_sk_...)".into());
        }
        let api_url = v["apiUrl"]
            .as_str()
            .unwrap_or("https://vm.cmux.dev")
            .trim_end_matches('/')
            .to_owned();
        if !api_url.starts_with("https://") {
            return Err("apiUrl must be https://".into());
        }
        Ok(Issuer {
            api_url,
            key,
            team: v["teamId"].as_str().map(str::to_owned),
            ttl_seconds: v["ttlSeconds"].as_u64().unwrap_or(4 * 3600),
            max_vms: v["maxVms"].as_u64().map_or(5, |n| n as u32),
            max_usd_per_hour: v["maxUsdPerHour"].as_f64().unwrap_or(2.0),
        })
    }

    fn request(&self, method: &str, path: &str) -> ureq::Request {
        let mut r = ureq::request(method, &format!("{}{path}", self.api_url))
            .set("authorization", &format!("Bearer {}", self.key))
            .set("accept", "application/json")
            .timeout(Duration::from_secs(30));
        if let Some(team) = &self.team {
            r = r.set("x-cmux-team-id", team);
        }
        r
    }

    /// The request body for subagent `agent`.
    pub fn issue_body(&self, agent: &str) -> Value {
        json!({
            "name": format!("chief subagent {agent}"),
            "ttlSeconds": self.ttl_seconds,
            "maxVms": self.max_vms,
            "maxUsdPerHour": self.max_usd_per_hour,
        })
    }

    /// The file the agent reads, from the service's answer: the key, where to
    /// use it, and its limits (no issuer credential).
    pub fn agent_file(&self, created: &Value) -> Result<AgentKey, String> {
        let id = created["id"]
            .as_str()
            .ok_or("the answer has no id")?
            .to_owned();
        let key = created["key"].as_str().ok_or("the answer has no key")?;
        let file = json!({
            "key": key,
            "keyId": id,
            "apiUrl": self.api_url,
            "expiresAt": created["expiresAt"],
            "maxVms": created["maxVms"],
            "maxUsdPerHour": created["maxUsdPerHour"],
            "labels": created["labels"],
        });
        Ok(AgentKey {
            id,
            file: format!("{file}\n"),
        })
    }
}

/// The service's message for a refused request, never the key.
fn refusal(e: ureq::Error) -> String {
    match e {
        ureq::Error::Status(code, response) => {
            let message = response
                .into_json::<Value>()
                .ok()
                .and_then(|v| v["message"].as_str().map(str::to_owned))
                .unwrap_or_default();
            format!("HTTP {code} {message}").trim().to_owned()
        }
        ureq::Error::Transport(t) => format!("cannot reach the cmux VM service: {}", t.kind()),
    }
}

impl AgentKeys for Issuer {
    fn issue(&self, agent: &str) -> Result<AgentKey, String> {
        let created: Value = self
            .request("POST", "/v1/agent-keys")
            .send_json(self.issue_body(agent))
            .map_err(refusal)?
            .into_json()
            .map_err(|e| format!("agent key answer: {e}"))?;
        self.agent_file(&created)
    }

    fn revoke(&self, key_id: &str) -> Result<(), String> {
        match self
            .request("DELETE", &format!("/v1/agent-keys/{key_id}"))
            .call()
        {
            Ok(_) => Ok(()),
            // Already gone (or another tenant's): nothing to revoke.
            Err(ureq::Error::Status(404, _)) => Ok(()),
            Err(e) => Err(refusal(e)),
        }
    }
}

/// Where the pool tool puts subagent `agent`'s key on the VM, under the VM
/// user's home.
pub fn vm_path(agent: &str) -> PathBuf {
    PathBuf::from(format!("~/.config/cmux/agents/{agent}.json"))
}

/// The lines a cloud subagent's task gets when it holds a key.
pub fn task_note(agent: &str) -> String {
    let path = vm_path(agent);
    format!(
        "# Your sandboxes\n\nYou hold your own cmux VM agent key for throwaway sandbox VMs; it reaches only the VMs you create. Start every shell that uses it with `export CMUX_AGENT_CONFIG={path}` (the file is mode 0600; never print, copy or commit the key). Then `cmux-sandbox create` (or `cmux sandbox create` where the cmux CLI has it) prints a VM id; `cmux-sandbox exec <vm> -- <command>`, `cmux-sandbox list`, `cmux-sandbox token <vm>` (a provider token for that VM only) and `cmux-sandbox delete <vm>`. Delete your sandboxes before you report; the key has a VM count and USD/h budget, and when it expires or you are done for a while, the service deletes what is left.",
        path = path.display()
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    const KEY: &str = "cmuxvm_sk_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";

    #[test]
    fn parses_an_issuer_with_defaults() {
        let issuer = Issuer::parse(&format!(
            r#"{{"key":"{KEY}","apiUrl":"https://vm-staging.cmux.dev/"}}"#
        ))
        .unwrap();
        assert_eq!(issuer.api_url, "https://vm-staging.cmux.dev");
        assert_eq!(
            issuer.issue_body("a7"),
            json!({"name": "chief subagent a7", "ttlSeconds": 14400, "maxVms": 5, "maxUsdPerHour": 2.0})
        );
        assert_eq!(issuer.team, None);
    }

    #[test]
    fn refuses_a_non_key_and_plain_http() {
        assert!(Issuer::parse(r#"{"key":"fs_team_key","apiUrl":"https://vm.cmux.dev"}"#).is_err());
        assert!(
            Issuer::parse(&format!(
                r#"{{"key":"{KEY}","apiUrl":"http://vm.cmux.dev"}}"#
            ))
            .is_err()
        );
    }

    #[test]
    fn the_agent_file_holds_the_agent_key_and_never_the_issuer_key() {
        let issuer = Issuer::parse(&format!(
            r#"{{"key":"{KEY}","apiUrl":"https://vm.cmux.dev","teamId":"team_x"}}"#
        ))
        .unwrap();
        let agent = issuer
            .agent_file(&json!({"id": "vmk_1", "key": "cmuxvm_sk_agent", "expiresAt": "2026-10-22T06:00:00Z", "maxVms": 5, "maxUsdPerHour": 2, "labels": {"cmux.agent": "vmk_1"}}))
            .unwrap();
        assert_eq!(agent.id, "vmk_1");
        let file: Value = serde_json::from_str(&agent.file).unwrap();
        assert_eq!(file["key"], "cmuxvm_sk_agent");
        assert_eq!(file["apiUrl"], "https://vm.cmux.dev");
        assert!(!agent.file.contains(KEY));
        assert!(!agent.file.contains("team_x"));
    }

    #[test]
    fn a_missing_issuer_file_turns_agent_keys_off() {
        let home = std::env::temp_dir().join(format!("agent-keys-{}", std::process::id()));
        assert_eq!(Issuer::load(&home).unwrap(), None);
    }

    #[cfg(unix)]
    #[test]
    fn a_readable_issuer_file_is_refused() {
        use std::os::unix::fs::PermissionsExt;
        let home = std::env::temp_dir().join(format!("agent-keys-mode-{}", std::process::id()));
        let file = home.join(ISSUER_FILE);
        std::fs::create_dir_all(file.parent().unwrap()).unwrap();
        std::fs::write(
            &file,
            format!(r#"{{"key":"{KEY}","apiUrl":"https://vm.cmux.dev"}}"#),
        )
        .unwrap();
        std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o644)).unwrap();
        assert!(Issuer::load(&home).unwrap_err().contains("0600"));
        std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o600)).unwrap();
        assert!(Issuer::load(&home).unwrap().is_some());
        std::fs::remove_dir_all(&home).unwrap();
    }

    #[test]
    fn the_task_note_names_the_file_and_never_a_key() {
        let note = task_note("a12");
        assert!(note.contains("CMUX_AGENT_CONFIG=~/.config/cmux/agents/a12.json"));
        assert!(!note.contains("cmuxvm_sk_"));
    }
}
