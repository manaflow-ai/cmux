use super::*;
use std::path::PathBuf;

struct World {
    _dir: tempfile::TempDir,
    top: PathBuf,
    chat: PathBuf,
    claude: project_mcp::Claude,
}

impl World {
    fn new() -> Self {
        let dir = tempfile::tempdir().unwrap();
        let top = dir.path().canonicalize().unwrap();
        let chat = top.join("chat");
        std::fs::create_dir_all(&chat).unwrap();
        let claude = project_mcp::Claude {
            configs: vec![top.join(".claude.json")],
            settings: vec![top.join("settings.json")],
            managed: vec![top.join("managed-settings.json")],
            managed_mcp: top.join("managed-mcp.json"),
        };
        Self { _dir: dir, top, chat, claude }
    }

    fn write(&self, path: &Path, value: Value) {
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, value.to_string()).unwrap();
    }

    fn shared(&self, share: &Share) -> Map<String, Value> {
        let taken = BTreeSet::from(["cmux".to_owned()]);
        claude_with(&self.claude, share, &BTreeMap::new(), &self.chat, &taken, |spec| {
            Some(serde_json::to_value(spec).unwrap())
        })
    }
}

#[test]
fn share_reads_env_over_setting() {
    let env = BTreeMap::from([(SHARE_ENV.to_owned(), "fs, git".to_owned())]);
    assert_eq!(
        Share::of(&env, Some(r#"{"agents": {"mcpServers": {"share": true}}}"#)),
        Share::Names(BTreeSet::from(["fs".to_owned(), "git".to_owned()]))
    );
    let none = BTreeMap::from([(SHARE_ENV.to_owned(), "0".to_owned())]);
    assert_eq!(
        Share::of(&none, Some(r#"{"agents": {"mcpServers": {"share": true}}}"#)),
        Share::None
    );
}

#[test]
fn claude_shares_user_local_and_project_servers_by_their_precedence() {
    let w = World::new();
    let chat = w.chat.to_str().unwrap();
    w.write(
        &w.top.join(".claude.json"),
        json!({
            "mcpServers": {
                "fs": {"command": "npx", "args": ["-y", "fs-user"]},
                "web": {"type": "http", "url": "https://example.test/mcp"},
                "secret": {"command": "srv", "env": {"TOKEN": "${TOKEN}"}},
                "off": {"command": "off-srv"},
                "cmux": {"command": "someone-elses-cmux"},
                "proj": {"command": "user-proj"},
            },
            "projects": {chat: {
                "mcpServers": {"fs": {"command": "npx", "args": ["-y", "fs-local"], "env": {"A": "1"}}},
                "disabledMcpServers": ["off"],
            }},
        }),
    );
    w.write(
        &w.chat.join(".mcp.json"),
        json!({"mcpServers": {"proj": {"command": "project-proj"}}}),
    );
    let got = w.shared(&Share::All);
    let names: Vec<&str> = got.keys().map(String::as_str).collect();
    assert_eq!(
        names,
        ["fs", "proj"],
        "http, ${{}}, disabled and cmux's own name stay the harness's"
    );
    assert_eq!(got["fs"]["args"], json!(["-y", "fs-local"]), "local scope wins");
    assert_eq!(got["fs"]["env"], json!({"A": "1"}));
    assert_eq!(got["fs"]["cwd"], json!(w.chat), "runs where Claude would run it");
    assert_eq!(got["proj"]["command"], "project-proj", "project scope over user scope");
    // Only names the person shares.
    let only = w.shared(&Share::Names(BTreeSet::from(["proj".to_owned()])));
    assert_eq!(only.keys().collect::<Vec<_>>(), ["proj"]);
    assert!(w.shared(&Share::None).is_empty());
}

#[test]
fn claude_shares_nothing_under_a_managed_server_list() {
    let w = World::new();
    w.write(&w.top.join(".claude.json"), json!({"mcpServers": {"fs": {"command": "npx"}}}));
    w.write(&w.top.join("managed-mcp.json"), json!({"mcpServers": {}}));
    assert!(w.shared(&Share::All).is_empty());
}

#[test]
fn claude_leaves_a_denied_server_to_claude() {
    let w = World::new();
    w.write(
        &w.top.join(".claude.json"),
        json!({"mcpServers": {"fs": {"command": "npx"}, "ok": {"command": "ok"}}}),
    );
    w.write(
        &w.top.join("managed-settings.json"),
        json!({"deniedMcpServers": [{"serverName": "fs"}]}),
    );
    assert_eq!(w.shared(&Share::All).keys().collect::<Vec<_>>(), ["ok"]);
}

#[test]
fn codex_shares_enabled_stdio_servers() {
    let text = r#"
[mcp_servers.fs]
command = "npx"
args = ["-y", "fs"]
env = { A = "1" }

[mcp_servers.off]
command = "off"
enabled = false

[mcp_servers.web]
url = "https://example.test/mcp"

[mcp_servers.cmux]
command = "cmux"
"#;
    let taken = BTreeSet::from(["cmux".to_owned()]);
    let cwd = Path::new("/work");
    let got = codex_with(text, &Share::All, &BTreeMap::new(), cwd, &taken, |spec| {
        assert_eq!(spec.command, "npx");
        assert_eq!(spec.env.get("A").map(String::as_str), Some("1"));
        assert_eq!(spec.cwd.as_deref(), Some(cwd));
        Some(("/bin/acpmux".to_owned(), vec!["mcp-shim".to_owned(), spec.key()]))
    });
    assert_eq!(got.len(), 1);
    assert_eq!(got[0]["name"], "fs");
    assert_eq!(got[0]["command"], "/bin/acpmux");
}

#[test]
fn same_launch_same_key() {
    let spec = |cwd: &str| Spec {
        command: "npx".into(),
        args: vec!["a".into()],
        env: BTreeMap::new(),
        cwd: Some(cwd.into()),
    };
    assert_eq!(spec("/a").key(), spec("/a").key());
    assert_ne!(spec("/a").key(), spec("/b").key());
}
