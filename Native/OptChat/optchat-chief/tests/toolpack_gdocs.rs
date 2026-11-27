//! The Google Docs tool pack (plans/cmux-next/chief-gdocs-DESIGN.md): a
//! shipped pack whose CLI is a script it carries (`[tool] script`), on the
//! turn's PATH, that reads, edits and verifies Docs through the person's
//! browser session or a Drive token. The browser is a fake `cmux` that
//! behaves like the Docs editor (tests/fixtures/gdocs/fake_cmux.py); the
//! Drive API is a local HTTP server. No network, no real doc.

use std::io::{BufRead, BufReader, Read, Write};
use std::net::TcpListener;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::sync::{Arc, Mutex};

use optchat_chief::prompt::Tools;
use optchat_chief::session_dir::{SessionSetup, write};
use optchat_chief::toolpacks;

fn fixtures() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/gdocs")
}

fn setup(paths: &optchat_chief::paths::Paths) -> SessionSetup {
    SessionSetup {
        exe: "/x/optchat-chief".into(),
        env: Default::default(),
        instructions: None,
        tools: Tools::Cli(paths.bin.join("chief").display().to_string()),
        user_env: Default::default(),
        profile_tool: false,
        chiefs_tool: false,
    }
}

/// A Chief home with its session written: the turn's `bin/gdocs`.
fn chief() -> (tempfile::TempDir, optchat_chief::paths::Paths) {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().join("default");
    let paths = optchat_chief::paths::Paths::new(&home);
    paths.create().unwrap();
    write(&paths, &setup(&paths)).unwrap();
    (dir, paths)
}

/// Runs the turn's `gdocs` with the fake browser, retrying while a parallel
/// test's fork holds a script open for write (ETXTBSY).
fn gdocs(
    paths: &optchat_chief::paths::Paths,
    dir: &Path,
    args: &[&str],
    env: &[(&str, &str)],
) -> Output {
    let fake = fixtures().join("fake_cmux.py");
    let mut cmd = Command::new(paths.bin.join("gdocs"));
    cmd.args(args)
        .env(
            "PATH",
            format!(
                "{}:/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin",
                paths.bin.display()
            ),
        )
        .env("GDOCS_CMUX", &fake)
        .env("GDOCS_FAKE_STATE", dir.join("state.json"))
        .env("GDOCS_FAKE_LOG", dir.join("calls.log"))
        .env_remove("GDOCS_TOKEN")
        .env_remove("GDOCS_TAB");
    for (k, v) in env {
        cmd.env(k, v);
    }
    for _ in 0..50 {
        match cmd.output() {
            Err(e) if e.kind() == std::io::ErrorKind::ExecutableFileBusy => {
                std::thread::sleep(std::time::Duration::from_millis(20));
            }
            result => return result.unwrap(),
        }
    }
    cmd.output().unwrap()
}

fn json_of(out: &Output) -> serde_json::Value {
    serde_json::from_slice(&out.stdout).unwrap_or_else(|e| {
        panic!(
            "{e}: stdout={} stderr={}",
            String::from_utf8_lossy(&out.stdout),
            String::from_utf8_lossy(&out.stderr)
        )
    })
}

const DOC: &str = "https://docs.google.com/document/d/DOCID_FIXTURE_0123456789/edit";

#[test]
fn gdocs_the_gdocs_pack_ships_on_with_its_script_and_skill() {
    let names: Vec<&str> = toolpacks::BUILTIN.iter().map(|b| b.0).collect();
    assert!(names.contains(&"gdocs"), "{names:?}");
    let p = toolpacks::builtin("gdocs").unwrap();
    assert!(
        p.enabled,
        "on by default: no secret needed for the browser route"
    );
    assert_eq!(p.tool.bin, "gdocs");
    assert!(
        p.auth.is_some(),
        "an optional Drive token (device code or paste)"
    );
    assert_eq!(p.inject.as_ref().unwrap().env, ["GDOCS_TOKEN"]);
    assert!(
        p.share.is_none(),
        "never the person's own Google login by default"
    );

    // Written to the shared folder at host start with the script, executable.
    let dir = tempfile::tempdir().unwrap();
    let shared = dir.path().join("toolpacks");
    let written = toolpacks::install_builtin(&shared).unwrap();
    assert!(written.contains(&"gdocs".to_owned()), "{written:?}");
    let script = shared.join("gdocs").join("gdocs");
    assert!(script.exists());
    assert_eq!(
        std::fs::metadata(&script).unwrap().permissions().mode() & 0o111,
        0o111
    );
    let skill = std::fs::read_to_string(shared.join("gdocs").join("SKILL.md")).unwrap();
    let (name, _) = optchat_chief::skills::front_matter(&skill).unwrap();
    assert_eq!(name, "gdocs");
}

#[test]
fn gdocs_every_turn_has_gdocs_on_path_and_it_runs_with_no_token() {
    let (dir, paths) = chief();
    let wrapper = std::fs::read_to_string(paths.bin.join("gdocs")).unwrap();
    assert!(wrapper.contains("(tool pack gdocs"), "{wrapper}");
    assert!(
        paths
            .home
            .join("skills")
            .join("gdocs")
            .join("SKILL.md")
            .exists()
    );
    // No token stored: the chief launcher fails and the script still runs.
    std::fs::write(paths.bin.join("chief"), "#!/bin/sh\nexit 1\n").unwrap();
    let out = gdocs(&paths, dir.path(), &["md2html", "--md", "-"], &[]);
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    let md = fixtures().join("roadmap.md");
    let out = gdocs(
        &paths,
        dir.path(),
        &["md2html", "--md", md.to_str().unwrap()],
        &[],
    );
    let html = String::from_utf8_lossy(&out.stdout);
    assert!(html.starts_with("<h1>Roadmap (scratch)</h1>"), "{html}");
    assert!(html.contains("<ul><li>Spin up a VM from Chief<ul><li>Persist agent trajectories off the VM</li><li>Pair a Mac in one step</li></ul></li><li>Show cost per run</li>"), "{html}");
    assert!(
        html.contains("<b>draft</b>")
            && html.contains("<a href=\"https://example.com/tracker\">the tracker</a>")
    );
    assert!(
        html.contains("<table><tbody><tr><th>Area</th><th>Owner</th></tr>"),
        "{html}"
    );
}

#[test]
fn gdocs_read_parses_a_real_mobilebasic_page() {
    let (dir, paths) = chief();
    let page = fixtures().join("mobilebasic.html");
    let out = gdocs(
        &paths,
        dir.path(),
        &["parse-html", page.to_str().unwrap()],
        &[],
    );
    assert_eq!(
        String::from_utf8_lossy(&out.stdout),
        "# KEYMARK\n\n# Probe\n\nhello **bold**\n\n- one\n  - nested\u{2019}AFTERMARK\n- two\n\nTAILMARK\n\nHEADMARK\n"
    );
    let out = gdocs(
        &paths,
        dir.path(),
        &["parse-html", page.to_str().unwrap(), "--format", "json"],
        &[],
    );
    let v = json_of(&out);
    assert_eq!(
        v["comments"],
        serde_json::json!([{"ref": "a", "text": "cmux probe comment"}])
    );
    assert_eq!(v["blocks"][4]["level"], 1, "nested bullet keeps its level");
}

#[test]
fn gdocs_replace_outline_reformats_a_30_bullet_doc_and_verifies_it() {
    let (dir, paths) = chief();
    let flat = std::fs::read_to_string(fixtures().join("roadmap-flat.txt")).unwrap();
    std::fs::write(
        dir.path().join("state.json"),
        serde_json::json!({"url": DOC, "lib": false, "mode": "editing", "sel": "end", "comments": [], "ready": {},
            "doc": flat.lines().map(|l| format!("<p>{l}</p>")).collect::<String>()})
        .to_string(),
    )
    .unwrap();
    let md = fixtures().join("roadmap.md");
    let out = gdocs(
        &paths,
        dir.path(),
        &[
            "replace-outline",
            DOC,
            "--tab",
            "tab_fake",
            "--md",
            md.to_str().unwrap(),
        ],
        &[],
    );
    let v = json_of(&out);
    assert!(out.status.success(), "{v}");
    assert_eq!(v["route"], "browser");
    assert_eq!(v["verify"]["ok"], true, "{v}");
    assert_eq!(v["verify"]["expected_blocks"], 42);
    // Select-all then one paste: the whole body in one undo step.
    let log = std::fs::read_to_string(dir.path().join("calls.log")).unwrap();
    let sel = log.find("G.selectAll()").expect("select-all");
    let paste = log.find("G.paste(").expect("paste");
    assert!(sel < paste);
    assert_eq!(log.matches("G.paste(").count(), 1);

    // read gives the outline back as Markdown.
    let out = gdocs(&paths, dir.path(), &["read", DOC, "--tab", "tab_fake"], &[]);
    let text = String::from_utf8_lossy(&out.stdout);
    assert!(
        text.contains(
            "## Cloud\n\n- Spin up a VM from Chief\n  - Persist agent trajectories off the VM\n"
        ),
        "{text}"
    );
    assert!(text.contains("| Cloud | Ada |"), "{text}");
}

#[test]
fn gdocs_verify_fails_when_the_editor_drops_the_nesting() {
    let (dir, paths) = chief();
    std::fs::write(
        dir.path().join("state.json"),
        serde_json::json!({"url": DOC, "lib": true, "mode": "editing", "sel": "end", "comments": [], "ready": {}, "doc": ""}).to_string(),
    )
    .unwrap();
    let md = fixtures().join("roadmap.md");
    let out = gdocs(
        &paths,
        dir.path(),
        &[
            "replace-outline",
            DOC,
            "--tab",
            "tab_fake",
            "--md",
            md.to_str().unwrap(),
            "--verify-timeout",
            "0",
        ],
        &[("GDOCS_FAKE_FLATTEN", "1")],
    );
    assert_eq!(out.status.code(), Some(1));
    let v = json_of(&out);
    assert_eq!(v["verify"]["ok"], false);
    assert!(
        v["verify"]["first_difference"]["expected"]
            .as_str()
            .unwrap()
            .starts_with("li."),
        "{v}"
    );
}

#[test]
fn gdocs_insert_after_text_comment_and_suggest_use_the_editor_not_keys_to_the_window() {
    let (dir, paths) = chief();
    std::fs::write(
        dir.path().join("state.json"),
        serde_json::json!({"url": DOC, "lib": false, "mode": "editing", "sel": "end", "comments": [], "ready": {},
            "doc": "<h1>Notes</h1><p>Intro line.</p><p>Last line.</p>"})
        .to_string(),
    )
    .unwrap();
    let out = gdocs(
        &paths,
        dir.path(),
        &[
            "insert",
            DOC,
            "--tab",
            "tab_fake",
            "--after",
            "Intro line.",
            "--inline",
            "--text",
            " Added **here**.",
        ],
        &[],
    );
    let v = json_of(&out);
    assert_eq!(v["verify"]["ok"], true, "{v}");
    let out = gdocs(
        &paths,
        dir.path(),
        &[
            "insert",
            DOC,
            "--tab",
            "tab_fake",
            "--at",
            "end",
            "--text",
            "- a\n  - b\n",
        ],
        &[],
    );
    assert_eq!(json_of(&out)["verify"]["ok"], true);
    let out = gdocs(
        &paths,
        dir.path(),
        &[
            "insert",
            DOC,
            "--tab",
            "tab_fake",
            "--after",
            "no such text",
            "--text",
            "x",
        ],
        &[],
    );
    assert_eq!(out.status.code(), Some(2));
    assert!(String::from_utf8_lossy(&out.stderr).contains("not_found"));

    let out = gdocs(
        &paths,
        dir.path(),
        &[
            "comment",
            DOC,
            "--tab",
            "tab_fake",
            "--on",
            "Last line",
            "--text",
            "Check this",
        ],
        &[],
    );
    let v = json_of(&out);
    assert_eq!(v["verify"]["ok"], true, "{v}");

    let out = gdocs(
        &paths,
        dir.path(),
        &[
            "insert",
            DOC,
            "--tab",
            "tab_fake",
            "--at",
            "start",
            "--suggest",
            "--text",
            "Proposal",
        ],
        &[],
    );
    assert!(out.status.success());
    let log = std::fs::read_to_string(dir.path().join("calls.log")).unwrap();
    let on = log.find("G.setMode('suggesting')").expect("suggesting on");
    let paste = log[on..].find("G.paste(").expect("paste as suggestion") + on;
    assert!(
        log[paste..].contains("G.setMode('editing')"),
        "back to editing after"
    );
    // Never a real key press to the tab (Docs ignores them in a background tab).
    assert!(!log.contains("\"press\""), "{log}");
}

/// A Drive API stand-in: export, upload, comments; records each request.
fn drive_server(doc: Arc<Mutex<String>>, seen: Arc<Mutex<Vec<String>>>) -> String {
    let l = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = format!("http://{}", l.local_addr().unwrap());
    std::thread::spawn(move || {
        for s in l.incoming() {
            let Ok(mut s) = s else { continue };
            let mut r = BufReader::new(s.try_clone().unwrap());
            let mut first = String::new();
            r.read_line(&mut first).unwrap();
            let mut len = 0;
            let mut auth = String::new();
            loop {
                let mut h = String::new();
                r.read_line(&mut h).unwrap();
                let lower = h.to_ascii_lowercase();
                if let Some(v) = lower.strip_prefix("content-length:") {
                    len = v.trim().parse().unwrap();
                }
                if lower.starts_with("authorization:") {
                    auth = h.trim().to_owned();
                }
                if h == "\r\n" || h.is_empty() {
                    break;
                }
            }
            let mut body = vec![0; len];
            r.read_exact(&mut body).unwrap();
            let body = String::from_utf8_lossy(&body).into_owned();
            seen.lock()
                .unwrap()
                .push(format!("{} {}", first.trim(), auth));
            let answer = if first.starts_with("GET ")
                && first.contains("/export?mimeType=text%2Fhtml")
            {
                format!("<html><body>{}</body></html>", doc.lock().unwrap())
            } else if first.starts_with("PATCH /upload/drive/v3/files/") {
                let inner = body
                    .split("<body>")
                    .nth(1)
                    .unwrap_or("")
                    .split("</body>")
                    .next()
                    .unwrap_or("")
                    .to_owned();
                *doc.lock().unwrap() = inner;
                "{\"id\":\"x\"}".to_owned()
            } else if first.starts_with("POST /drive/v3/files/") && first.contains("/comments") {
                "{\"id\":\"c1\"}".to_owned()
            } else {
                String::new()
            };
            let _ = write!(
                s,
                "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{answer}",
                answer.len()
            );
        }
    });
    addr
}

#[test]
fn gdocs_with_a_drive_token_it_uses_the_api_and_no_browser() {
    let (dir, paths) = chief();
    let doc = Arc::new(Mutex::new("<p>old</p>".to_owned()));
    let seen = Arc::new(Mutex::new(Vec::new()));
    let base = drive_server(doc.clone(), seen.clone());
    let env = [
        ("GDOCS_TOKEN", "ya29.test-token-0123456789"),
        ("GDOCS_API_BASE", base.as_str()),
    ];
    let md = fixtures().join("roadmap.md");
    let out = gdocs(
        &paths,
        dir.path(),
        &["replace-outline", DOC, "--md", md.to_str().unwrap()],
        &env,
    );
    let v = json_of(&out);
    assert_eq!(v["route"], "api", "{v}");
    assert_eq!(v["verify"]["ok"], true, "{v}");
    let out = gdocs(
        &paths,
        dir.path(),
        &["comment", DOC, "--on", "Pair a Mac", "--text", "why?"],
        &env,
    );
    assert_eq!(json_of(&out)["route"], "api");
    let seen = seen.lock().unwrap();
    assert!(
        seen.iter()
            .all(|l| l.ends_with("Authorization: Bearer ya29.test-token-0123456789")),
        "{seen:?}"
    );
    assert!(
        seen[0]
            .starts_with("PATCH /upload/drive/v3/files/DOCID_FIXTURE_0123456789?uploadType=media")
    );
    assert!(!dir.path().join("calls.log").exists(), "no browser call");
}
