//! A tool pack carries skills and MCP servers too
//! (plans/cmux-next/chief-toolpacks-DESIGN.md sections 3 and 6): enabling
//! one adds its skills and servers to a fresh Chief session, Claude Code's
//! `.mcp.json` and the codex turn's config.toml alike; disabling it takes
//! both away. A secret reaches a server only through `chief pack mcp`,
//! never a file the harness reads.

use std::io::Write;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::process::{Command, Stdio};

use optchat_chief::prompt::Tools;
use optchat_chief::session_dir::{SessionSetup, write};
use optchat_chief::toolpacks::{self, FileStore, Store};

const SECRET: &str = "acme_0123456789abcdefABCDEF0123";

fn acme(enabled: bool, server: &Path) -> String {
    format!(
        r#"name = "acme"
title = "Acme"
enabled = {enabled}

[tool]
bin = "acme"

[auth]
methods = ["paste"]

[[mcp]]
name = "acme"
command = "{server}"
args = ["--stdio"]
env = {{ ACME_KEY = "secret:acme", ACME_MODE = "fast" }}
tools = ["acme_read"]

[[mcp]]
name = "acme-remote"
url = "https://mcp.acme.dev/mcp"

[[mcp]]
name = "acme-off"
url = "https://mcp.acme.dev/other"
enabled = false
"#,
        server = server.display()
    )
}

fn put(dir: &Path, text: &str) {
    std::fs::create_dir_all(dir.join("skills").join("acme-deploy")).unwrap();
    std::fs::write(dir.join("pack.toml"), text).unwrap();
    std::fs::write(
        dir.join("SKILL.md"),
        "---\nname: acme\ndescription: use acme\n---\nacme steps\n",
    )
    .unwrap();
    std::fs::write(
        dir.join("skills").join("acme-deploy").join("SKILL.md"),
        "---\nname: acme-deploy\ndescription: deploy with acme\n---\nsteps\n",
    )
    .unwrap();
}

struct Session {
    _dir: tempfile::TempDir,
    paths: optchat_chief::paths::Paths,
    setup: SessionSetup,
    user_codex: std::path::PathBuf,
    server: std::path::PathBuf,
}

fn session() -> Session {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().join("default");
    let paths = optchat_chief::paths::Paths::new(&home);
    paths.create().unwrap();
    let setup = SessionSetup {
        exe: "/x/optchat-chief".into(),
        env: Default::default(),
        instructions: None,
        tools: Tools::Cli(paths.bin.join("chief").display().to_string()),
        user_env: Default::default(),
        profile_tool: false,
        chiefs_tool: false,
    };
    let user_codex = dir.path().join("user-codex");
    std::fs::create_dir_all(&user_codex).unwrap();
    // A stdio MCP server that answers tools/list with two tools and says
    // which env it got.
    let server = dir.path().join("acme-mcp");
    std::fs::write(
        &server,
        "#!/bin/sh\nwhile IFS= read -r line; do\n  case \"$line\" in\n    *tools/list*) echo '{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"tools\":[{\"name\":\"acme_read\"},{\"name\":\"acme_delete\"}]}}' ;;\n    *tools/call*) echo \"{\\\"jsonrpc\\\":\\\"2.0\\\",\\\"id\\\":2,\\\"result\\\":{\\\"content\\\":[{\\\"type\\\":\\\"text\\\",\\\"text\\\":\\\"key=$ACME_KEY mode=$ACME_MODE\\\"}]}}\" ;;\n  esac\ndone\n",
    )
    .unwrap();
    std::fs::set_permissions(&server, std::fs::Permissions::from_mode(0o755)).unwrap();
    Session {
        _dir: dir,
        paths,
        setup,
        user_codex,
        server,
    }
}

fn turn(s: &Session) -> (serde_json::Value, serde_json::Value, toml::Table) {
    write(&s.paths, &s.setup).unwrap();
    optchat_chief::codex_home::prepare_turn_codex_home(&s.paths, &s.user_codex).unwrap();
    let mcp: serde_json::Value =
        serde_json::from_slice(&std::fs::read(s.paths.session.join(".mcp.json")).unwrap()).unwrap();
    let settings: serde_json::Value = serde_json::from_slice(
        &std::fs::read(s.paths.session.join(".claude").join("settings.json")).unwrap(),
    )
    .unwrap();
    let codex: toml::Table = std::fs::read_to_string(s.paths.turn_codex.join("config.toml"))
        .unwrap()
        .parse()
        .unwrap();
    (mcp, settings, codex)
}

#[test]
fn enabling_a_pack_adds_its_skills_and_servers_and_disabling_removes_them() {
    let s = session();
    let home = &s.paths.home;
    let pack_dir = toolpacks::chief_dir(home).join("acme");
    put(&pack_dir, &acme(true, &s.server));
    let pack = toolpacks::load(home)
        .into_iter()
        .find(|p| p.name == "acme")
        .unwrap();
    FileStore {
        path: toolpacks::secret_file(home, "acme"),
        pack,
    }
    .set(SECRET)
    .unwrap();

    let (mcp, settings, codex) = turn(&s);
    let servers = &mcp["mcpServers"];
    assert!(
        servers["optchat"].is_object(),
        "the Chief's own server stays"
    );
    // Claude Code: the secret-bearing stdio server runs through the launcher.
    let local = &servers["acme"];
    assert_eq!(local["type"], "stdio");
    assert_eq!(
        local["command"],
        s.paths.bin.join("chief").display().to_string()
    );
    assert_eq!(
        local["args"],
        serde_json::json!(["pack", "mcp", "acme", "acme"])
    );
    assert_eq!(servers["acme-remote"]["type"], "http");
    assert_eq!(servers["acme-remote"]["url"], "https://mcp.acme.dev/mcp");
    assert!(
        servers.get("acme-off").is_none(),
        "a server turned off stays out"
    );
    let enabled = settings["enabledMcpjsonServers"].as_array().unwrap();
    assert!(enabled.contains(&"acme".into()) && enabled.contains(&"acme-remote".into()));
    // Codex: the same servers, the allowed tools enforced by codex.
    let servers = codex["mcp_servers"].as_table().unwrap();
    assert_eq!(
        servers["acme"]["command"].as_str(),
        Some(s.paths.bin.join("chief").display().to_string().as_str())
    );
    assert_eq!(
        servers["acme"]["enabled_tools"].as_array().unwrap().len(),
        1
    );
    assert_eq!(
        servers["acme-remote"]["url"].as_str(),
        Some("https://mcp.acme.dev/mcp")
    );
    assert!(!servers.contains_key("acme-off"));
    // Both skills, in this Chief's own skills folder.
    let skills = optchat_chief::skills::chief_dir(home);
    assert!(skills.join("acme").join("SKILL.md").exists());
    assert!(skills.join("acme-deploy").join("SKILL.md").exists());
    // The shipped packs' skills too (github, cmux, browser are on by default).
    assert!(skills.join("github-signin").join("SKILL.md").exists());
    // No secret in anything the harness reads.
    for f in [
        s.paths.session.join(".mcp.json"),
        s.paths.session.join(".claude").join("settings.json"),
        s.paths.turn_codex.join("config.toml"),
    ] {
        assert!(
            !std::fs::read_to_string(&f).unwrap().contains(SECRET),
            "{}",
            f.display()
        );
    }

    // The launcher hands the secret to the server and keeps only the allowed tools.
    let mut child = Command::new(env!("CARGO_BIN_EXE_optchat-chief"))
        .args(["pack", "mcp", "acme", "acme", "--mux-home"])
        .arg(home)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(b"{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}\n{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"acme_delete\"}}\n{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"acme_read\"}}\n")
        .unwrap();
    let out = String::from_utf8(child.wait_with_output().unwrap().stdout).unwrap();
    let lines: Vec<serde_json::Value> = out
        .lines()
        .map(|l| serde_json::from_str(l).unwrap())
        .collect();
    let list = lines.iter().find(|l| l["id"] == 1).unwrap();
    assert_eq!(
        list["result"]["tools"],
        serde_json::json!([{"name": "acme_read"}])
    );
    let refused = lines.iter().find(|l| l["id"] == 3).unwrap();
    assert!(refused["error"].is_object(), "{refused}");
    let call = lines.iter().find(|l| l["id"] == 2).unwrap();
    assert_eq!(
        call["result"]["content"][0]["text"],
        format!("key={SECRET} mode=fast")
    );

    // Off: the servers and the skills go with the next session.
    put(&pack_dir, &acme(false, &s.server));
    let (mcp, settings, codex) = turn(&s);
    assert!(mcp["mcpServers"].get("acme").is_none());
    assert!(mcp["mcpServers"].get("acme-remote").is_none());
    assert!(
        !settings["enabledMcpjsonServers"]
            .as_array()
            .unwrap()
            .contains(&"acme".into())
    );
    assert!(
        codex
            .get("mcp_servers")
            .and_then(|m| m.get("acme"))
            .is_none()
    );
    assert!(!skills.join("acme").exists());
    assert!(!skills.join("acme-deploy").exists());
    assert!(skills.join("github-signin").join("SKILL.md").exists());
}

#[test]
fn a_users_own_skill_of_the_same_name_wins_and_bad_servers_are_refused() {
    let s = session();
    let home = &s.paths.home;
    let skills = optchat_chief::skills::chief_dir(home);
    std::fs::create_dir_all(skills.join("acme")).unwrap();
    std::fs::write(skills.join("acme").join("SKILL.md"), "mine").unwrap();
    put(
        &toolpacks::chief_dir(home).join("acme"),
        &acme(true, &s.server),
    );
    turn(&s);
    assert_eq!(
        std::fs::read_to_string(skills.join("acme").join("SKILL.md")).unwrap(),
        "mine"
    );
    assert!(skills.join("acme-deploy").join("SKILL.md").exists());

    let base = acme(true, &s.server);
    for bad in [
        base.replace("name = \"acme-remote\"", "name = \"optchat\""),
        base.replace("https://mcp.acme.dev/mcp", "file:///etc/passwd"),
        base.replace("\"secret:acme\"", "\"secret:../x\""),
        base.replace("name = \"acme-remote\"", "name = \"acme remote\""),
    ] {
        assert!(toolpacks::parse(&bad).is_err(), "{bad}");
    }
}
