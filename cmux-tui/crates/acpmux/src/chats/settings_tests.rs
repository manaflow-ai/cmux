use super::*;
use serde_json::json;

struct Dir(PathBuf);

impl Drop for Dir {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn temp(tag: &str) -> Dir {
    let base = std::env::temp_dir().join(format!("acpmux-probe-{tag}-{}", uuid::Uuid::now_v7()));
    fs::create_dir_all(&base).unwrap();
    Dir(fs::canonicalize(&base).unwrap())
}

fn touch(path: &Path) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, b"").unwrap();
}

fn kinds(path: &Path) -> Vec<(AdapterKind, PathBuf)> {
    probe(path).into_iter().map(|spec| (spec.harness, spec.path)).collect()
}

#[test]
fn params_default_to_on_and_dedupe_roots() {
    assert_eq!(ChatSettings::from_params(&json!({})).unwrap(), ChatSettings::default());
    let s = ChatSettings::from_params(&json!({
        "enabled": false, "discovery": false,
        "roots": ["/a", "/b", "/a"], "managedRoots": ["/m"]
    }))
    .unwrap();
    assert!(!s.enabled && !s.discovery);
    assert_eq!(s.roots, vec![PathBuf::from("/a"), PathBuf::from("/b")]);
    assert_eq!(s.managed_roots, vec![PathBuf::from("/m")]);
    for bad in [
        json!({"enabled": 1}),
        json!({"discovery": "no"}),
        json!({"roots": "/a"}),
        json!({"managedRoots": [true]}),
        json!({"roots": vec!["/x"; ChatSettings::MAX_ROOTS + 1]}),
    ] {
        assert!(ChatSettings::from_params(&bad).is_err(), "{bad} must fail");
    }
}

#[test]
fn settings_round_trip_through_the_file() {
    let dir = temp("file");
    let path = dir.0.join("sub/chat-settings.json");
    assert_eq!(ChatSettings::load(&path), ChatSettings::default());
    let s = ChatSettings {
        enabled: false,
        discovery: true,
        roots: vec![PathBuf::from("/r")],
        managed_roots: vec![PathBuf::from("/m")],
    };
    s.save(&path).unwrap();
    assert_eq!(ChatSettings::load(&path), s);
    fs::write(&path, b"{not json").unwrap();
    assert_eq!(ChatSettings::load(&path), ChatSettings::default());
}

#[test]
fn the_probe_finds_each_harness_from_the_layout() {
    let d = temp("layout");
    let root = &d.0;
    // Claude home and its projects folder.
    fs::create_dir_all(root.join("claude-home/projects")).unwrap();
    assert_eq!(
        kinds(&root.join("claude-home")),
        vec![(AdapterKind::ClaudeCode, root.join("claude-home/projects"))]
    );
    assert_eq!(
        kinds(&root.join("claude-home/projects")),
        vec![(AdapterKind::ClaudeCode, root.join("claude-home/projects"))]
    );
    // Codex home: sessions/ or the state database.
    fs::create_dir_all(root.join("codex-a/sessions")).unwrap();
    assert_eq!(kinds(&root.join("codex-a")), vec![(AdapterKind::Codex, root.join("codex-a"))]);
    touch(&root.join("codex-b/state_5.sqlite"));
    assert_eq!(kinds(&root.join("codex-b")), vec![(AdapterKind::Codex, root.join("codex-b"))]);
    // Pi: ~/.pi, <agent>/sessions.
    fs::create_dir_all(root.join(".pi/agent/sessions")).unwrap();
    assert_eq!(kinds(&root.join(".pi")), vec![(AdapterKind::Pi, root.join(".pi/agent/sessions"))]);
    assert_eq!(
        kinds(&root.join(".pi/agent")),
        vec![(AdapterKind::Pi, root.join(".pi/agent/sessions"))]
    );
    // OpenCode data folder, or its parent.
    touch(&root.join("share/opencode/opencode.db"));
    assert_eq!(
        kinds(&root.join("share")),
        vec![(AdapterKind::OpenCode, root.join("share/opencode"))]
    );
    // Gemini CLI.
    fs::create_dir_all(root.join(".gemini/tmp/abc/chats")).unwrap();
    assert_eq!(kinds(&root.join(".gemini")), vec![(AdapterKind::Gemini, root.join(".gemini"))]);
    // Cursor agent.
    fs::create_dir_all(root.join(".cursor/chats")).unwrap();
    assert_eq!(
        kinds(&root.join(".cursor")),
        vec![(AdapterKind::CursorAgent, root.join(".cursor/chats"))]
    );
    // Amp threads.
    touch(&root.join("amp/threads/T-1.json"));
    assert_eq!(kinds(&root.join("amp")), vec![(AdapterKind::Amp, root.join("amp/threads"))]);
    // Nothing known; a missing folder; a relative path.
    fs::create_dir_all(root.join("plain")).unwrap();
    assert!(kinds(&root.join("plain")).is_empty());
    assert!(kinds(&root.join("missing")).is_empty());
    assert!(kinds(Path::new("relative")).is_empty());
}

#[test]
fn root_specs_refuse_before_probing_and_mark_managed_roots() {
    let d = temp("specs");
    fs::create_dir_all(d.0.join("ok/projects")).unwrap();
    fs::create_dir_all(d.0.join("guarded/projects")).unwrap();
    let guarded = d.0.join("guarded");
    let s = ChatSettings {
        roots: vec![d.0.join("ok"), d.0.join("nothing"), guarded.clone()],
        managed_roots: vec![d.0.join("ok")],
        ..ChatSettings::default()
    };
    let refuse = |path: &Path| (path == guarded).then(|| "guarded here".to_owned());
    let (specs, refused) = s.root_specs(&refuse);
    assert_eq!(
        specs,
        vec![RootSpec {
            harness: AdapterKind::ClaudeCode,
            path: d.0.join("ok/projects"),
            label: None
        }]
    );
    let summary: Vec<(PathBuf, bool, bool)> = refused
        .iter()
        .map(|r| (r.path.clone(), r.managed, r.reason.contains("guarded here")))
        .collect();
    assert_eq!(summary, vec![(d.0.join("nothing"), false, false), (guarded, false, true)]);
    assert!(refused[0].reason.contains("is not a folder"), "{}", refused[0].reason);
}
