use super::*;

const CMUX: &str = "/opt/cmux/bin/cmux-tui";

struct World {
    _dir: tempfile::TempDir,
    /// Outside the repository: never filling.
    top: PathBuf,
    repo: PathBuf,
    claude: Claude,
}

impl World {
    fn new() -> Self {
        let dir = tempfile::tempdir().unwrap();
        let top = dir.path().canonicalize().unwrap();
        let repo = top.join("repo");
        std::fs::create_dir_all(repo.join("app/web")).unwrap();
        let claude = Claude {
            configs: vec![top.join(".claude.json")],
            settings: vec![top.join("settings.json"), repo.join(".claude/settings.local.json")],
            managed: vec![top.join("managed-settings.json")],
            managed_mcp: top.join("managed-mcp.json"),
        };
        Self { _dir: dir, top, repo, claude }
    }

    fn write(&self, path: &Path, value: Value) {
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, value.to_string()).unwrap();
    }

    fn servers(&self, folder: &Path, servers: Value) {
        self.write(&folder.join(".mcp.json"), json!({"mcpServers": servers}));
    }

    /// The servers wrapped for a chat in `cwd` while the repository fills.
    fn wrapped(&self, cwd: &Path) -> Map<String, Value> {
        wrapped(cwd, &self.claude, Path::new(CMUX), |folder| folder.starts_with(&self.repo))
    }
}

fn stdio(command: &str) -> Value {
    json!({"command": command, "args": ["--stdio"], "env": {"TOKEN": "${TOKEN}"}})
}

/// Claude Code 2.1.305 starts a project server no list names (measured): it is wrapped, under its
/// own name, with its env, to start in the chat's folder.
#[test]
fn a_server_claude_would_start_is_wrapped_under_its_name() {
    let world = World::new();
    world.servers(&world.repo, json!({"local": stdio("node")}));
    let wrapped = world.wrapped(&world.repo);
    let repo = world.repo.to_str().unwrap();
    assert_eq!(
        wrapped,
        *json!({"local": {
            "type": "stdio",
            "command": CMUX,
            "args": ["repo", "mcp-lazy", repo, "--", "node", "--stdio"],
            "env": {"TOKEN": "${TOKEN}"},
        }})
        .as_object()
        .unwrap()
    );
    // Approved by name or for every project: the same.
    world.write(&world.top.join("settings.json"), json!({"enabledMcpjsonServers": ["local"]}));
    assert_eq!(world.wrapped(&world.repo).len(), 1);
    world.write(&world.top.join("settings.json"), json!({"enableAllProjectMcpServers": true}));
    assert_eq!(world.wrapped(&world.repo).len(), 1);
}

/// A server Claude would not start is never wrapped: approval never widens.
#[test]
fn a_disabled_server_is_left_alone() {
    let world = World::new();
    world.servers(&world.repo, json!({"off": stdio("a"), "local": stdio("b"), "on": stdio("c")}));
    let local = world.repo.join(".claude/settings.local.json");
    world.write(&local, json!({"disabledMcpjsonServers": ["local"]}));
    let key = world.repo.to_str().unwrap();
    let projects = json!({"projects": {key: {"disabledMcpjsonServers": ["off"]}}});
    world.write(&world.top.join(".claude.json"), projects);
    let kept = names(&world.wrapped(&world.repo));
    assert_eq!(kept, ["on"]);
}

/// An `http` or `sse` server reads no checkout; an entry with no command is not a stdio server.
#[test]
fn a_server_of_another_type_is_left_alone() {
    let world = World::new();
    world.servers(
        &world.repo,
        json!({
            "remote": {"type": "http", "url": "https://example.com/mcp"},
            "events": {"type": "sse", "url": "https://example.com/sse"},
            "local": {"type": "stdio", "command": "node"},
        }),
    );
    let kept = names(&world.wrapped(&world.repo));
    assert_eq!(kept, ["local"]);
}

/// A chat below the root gets its folder's servers and each parent's up to the repository's
/// root, a closer one winning a name; a folder outside the checkout is whole already.
#[test]
fn a_nested_chat_gets_the_servers_of_each_folder_still_filling() {
    let world = World::new();
    let web = world.repo.join("app/web");
    world.servers(&world.top, json!({"outside": stdio("o")}));
    world.servers(&world.repo, json!({"root": stdio("r"), "shared": stdio("from-root")}));
    world.servers(&web, json!({"shared": stdio("from-web"), "web": stdio("w")}));
    let wrapped = world.wrapped(&web);
    let kept = names(&wrapped);
    assert_eq!(kept, ["root", "shared", "web"]);
    assert_eq!(wrapped["shared"]["args"][4], "from-web");
    assert_eq!(wrapped["root"]["args"][2], web.to_str().unwrap(), "it starts in the chat's folder");
}

/// A closer folder's server of another type keeps its name: a parent's stdio server of that name
/// is not wrapped in its place (it would replace the closer one through `--mcp-config`).
#[test]
fn a_closer_server_of_another_type_keeps_its_name() {
    let world = World::new();
    let web = world.repo.join("app/web");
    world.servers(&world.repo, json!({"api": stdio("parent"), "root": stdio("r")}));
    world.servers(&web, json!({"api": {"type": "http", "url": "https://example.com/mcp"}}));
    assert_eq!(names(&world.wrapped(&web)), ["root"]);
}

/// A local-scope server in `.claude.json` takes a project server's name: the project's is not
/// wrapped over it.
#[test]
fn a_local_server_of_the_same_name_is_left_alone() {
    let world = World::new();
    world.servers(&world.repo, json!({"shared": stdio("project"), "kept": stdio("k")}));
    let key = world.repo.to_str().unwrap();
    world.write(
        &world.top.join(".claude.json"),
        json!({"projects": {key: {"mcpServers": {"shared": stdio("local")}}}}),
    );
    assert_eq!(names(&world.wrapped(&world.repo)), ["kept"]);
}

/// Every managed policy source counts: a drop-in's deny by command keeps its server unwrapped,
/// an allowance by command alone leaves the server to Claude (the wrapper's command would not
/// match it), and a policy this cannot read as JSON that names MCP, or an MCP rule it does not
/// model, wraps nothing.
#[test]
fn every_managed_policy_source_counts() {
    let mut world = World::new();
    world.servers(&world.repo, json!({"a": stdio("a"), "b": stdio("b"), "c": stdio("c")}));
    let dropin = world.top.join("managed-settings.d/10-deny.json");
    world.claude.managed.push(dropin.clone());
    world.write(&dropin, json!({"deniedMcpServers": [{"serverCommand": ["a", "--stdio"]}]}));
    assert_eq!(names(&world.wrapped(&world.repo)), ["b", "c"]);

    world.write(
        &dropin,
        json!({"allowedMcpServers": [{"serverCommand": ["b", "--stdio"]}, {"serverName": "c"}]}),
    );
    assert_eq!(names(&world.wrapped(&world.repo)), ["c"], "an allowance by command alone");

    world.write(&dropin, json!({"allowManagedMcpServersOnly": true}));
    assert!(world.wrapped(&world.repo).is_empty(), "an MCP rule it does not model");

    std::fs::remove_file(&dropin).unwrap();
    let plist = world.top.join("com.anthropic.claudecode.plist");
    world.claude.managed.push(plist.clone());
    std::fs::write(&plist, "<plist><dict><key>deniedMcpServers</key></dict></plist>").unwrap();
    assert!(world.wrapped(&world.repo).is_empty(), "a property list that names MCP");
    std::fs::write(&plist, "<plist><dict><key>model</key></dict></plist>").unwrap();
    assert_eq!(names(&world.wrapped(&world.repo)), ["a", "b", "c"]);
}

/// A server a project settings file above the checkout disables is never wrapped.
#[test]
fn settings_above_the_checkout_disable_too() {
    let world = World::new();
    world.servers(&world.repo, json!({"local": stdio("node"), "kept": stdio("k")}));
    world.write(
        &world.top.join(".claude/settings.json"),
        json!({"disabledMcpjsonServers": ["local"]}),
    );
    assert_eq!(names(&world.wrapped(&world.repo)), ["kept"]);
}

/// With no `CLAUDE_CONFIG_DIR`, the launch profile's `HOME` names a Claude home whose settings
/// and `.claude.json` count; with one, only that directory does.
#[test]
fn the_launch_profiles_home_counts() {
    let world = World::new();
    let home = world.top.join("profile-home");
    let env = BTreeMap::from([("HOME".to_owned(), home.to_string_lossy().into_owned())]);
    let claude = Claude::of(&env, &world.repo);
    assert!(claude.settings.contains(&home.join(".claude/settings.json")), "{:?}", claude.settings);
    assert!(claude.configs.contains(&home.join(".claude.json")), "{:?}", claude.configs);
    assert!(claude.managed.contains(&home.join(".claude/remote-settings.json")), "remote settings");
    let dir = world.top.join("config-dir");
    let env = BTreeMap::from([
        ("HOME".to_owned(), home.to_string_lossy().into_owned()),
        ("CLAUDE_CONFIG_DIR".to_owned(), dir.to_string_lossy().into_owned()),
    ]);
    let claude = Claude::of(&env, &world.repo);
    assert!(claude.settings.contains(&dir.join("settings.json")));
    assert!(!claude.settings.contains(&home.join(".claude/settings.json")));
}

/// A chat folder reached through a link counts as the folder it names, as Claude resolves it:
/// its parents are the repository's, so the root's servers are wrapped, DIR is the real folder,
/// and `projects` keys are the real paths.
#[cfg(unix)]
#[test]
fn a_linked_chat_folder_counts_as_its_real_folder() {
    let world = World::new();
    let web = world.repo.join("app/web");
    world.servers(&world.repo, json!({"root": stdio("r"), "off": stdio("o")}));
    let key = web.to_str().unwrap();
    let projects = json!({"projects": {key: {"disabledMcpjsonServers": ["off"]}}});
    world.write(&world.top.join(".claude.json"), projects);
    let link = world.top.join("chat");
    std::os::unix::fs::symlink(&web, &link).unwrap();
    let wrapped = world.wrapped(&link);
    assert_eq!(names(&wrapped), ["root"]);
    assert_eq!(wrapped["root"]["args"][2], key, "it starts in the real folder");
}

#[test]
fn a_whole_checkout_wraps_nothing() {
    let world = World::new();
    world.servers(&world.repo, json!({"local": stdio("node")}));
    assert!(wrapped(&world.repo, &world.claude, Path::new(CMUX), |_| false).is_empty());
}

#[test]
fn a_server_runs_in_the_chats_folder_as_claude_would_start_it() {
    let world = World::new();
    // Claude Code 2.1.305 starts it in its own folder whatever its `cwd` says (measured).
    let server = json!({"command": "./serve", "cwd": "tools"});
    world.servers(&world.repo, json!({"tools": server}));
    let entry = &world.wrapped(&world.repo)["tools"];
    assert_eq!(entry["args"][2], world.repo.to_str().unwrap());
    assert_eq!(entry["args"][4], "./serve");
    assert!(entry.get("cwd").is_none());
}

/// The managed policy decides before the project: a denied server, or one an allow list leaves
/// out, is not started by Claude, so it is not wrapped; with a `managed-mcp.json` Claude starts
/// no project server at all.
#[test]
fn the_managed_policy_is_kept() {
    let world = World::new();
    world.servers(&world.repo, json!({"a": stdio("a"), "b": stdio("b"), "c": stdio("c")}));
    let managed = world.top.join("managed-settings.json");
    world.write(&managed, json!({"deniedMcpServers": [{"serverCommand": ["a", "--stdio"]}]}));
    let kept = names(&world.wrapped(&world.repo));
    assert_eq!(kept, ["b", "c"]);
    world.write(&managed, json!({"allowedMcpServers": [{"serverName": "c"}]}));
    let kept = names(&world.wrapped(&world.repo));
    assert_eq!(kept, ["c"]);
    world.write(&world.top.join("managed-mcp.json"), json!({"mcpServers": {}}));
    assert!(world.wrapped(&world.repo).is_empty());
}

/// The wrapped servers join the chat's `--mcp-config`; cmux's own server keeps its name.
#[test]
fn the_config_holds_them_beside_cmuxs_own_servers() {
    let world = World::new();
    world.servers(&world.repo, json!({"cmux": stdio("theirs"), "local": stdio("node")}));
    let own = crate::agent_tools::McpServer {
        name: "cmux".to_owned(),
        command: "/bin/cmux".into(),
        args: vec!["mcp".to_owned(), "serve".to_owned()],
        env: vec![],
    };
    let tools = crate::agent_tools::AgentTools {
        servers: vec![own],
        project_servers: world.wrapped(&world.repo),
        ..Default::default()
    };
    let config = tools.mcp_config().unwrap();
    assert_eq!(config["mcpServers"]["cmux"]["command"], "/bin/cmux");
    assert_eq!(config["mcpServers"]["local"]["args"][1], "mcp-lazy");
    // Only project servers: the config is still written.
    let only = crate::agent_tools::AgentTools {
        project_servers: world.wrapped(&world.repo),
        ..Default::default()
    };
    let file = world.top.join("run/mcp/s.json");
    let args = only.claude_args(&file);
    assert_eq!(args, ["--mcp-config".to_owned(), file.to_string_lossy().into_owned()]);
    let written: Value = serde_json::from_slice(&std::fs::read(&file).unwrap()).unwrap();
    assert_eq!(written["mcpServers"]["local"]["command"], CMUX);
}

/// The server names, sorted.
fn names(servers: &Map<String, Value>) -> Vec<String> {
    let mut names: Vec<String> = servers.keys().cloned().collect();
    names.sort_unstable();
    names
}
