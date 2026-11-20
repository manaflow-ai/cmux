//! Tests of `artifacts_sync.rs`.

use super::*;
use serde_json::json;

/// A fake platform: answers each request by the first route whose `METHOD /path` starts its
/// request line, until the test drops it. A route listed again answers the next such request.
fn serve(
    routes: Vec<(&'static str, &'static str, String)>,
) -> (String, tokio::task::JoinHandle<()>) {
    let (url, task, _) = serve_recording(routes);
    (url, task)
}

/// `serve`, also keeping each request (head and body) it answered.
fn serve_recording(
    mut routes: Vec<(&'static str, &'static str, String)>,
) -> (String, tokio::task::JoinHandle<()>, Arc<std::sync::Mutex<Vec<String>>>) {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let log = Arc::new(std::sync::Mutex::new(Vec::new()));
    let seen = Arc::clone(&log);
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    listener.set_nonblocking(true).unwrap();
    let address = format!("http://{}", listener.local_addr().unwrap());
    let listener = tokio::net::TcpListener::from_std(listener).unwrap();
    let task = tokio::spawn(async move {
        loop {
            let (mut stream, _) = listener.accept().await.unwrap();
            let mut request = Vec::new();
            let mut buffer = [0; 4096];
            let head_end = loop {
                let size = stream.read(&mut buffer).await.unwrap();
                assert!(size > 0);
                request.extend_from_slice(&buffer[..size]);
                if let Some(at) = request.windows(4).position(|bytes| bytes == b"\r\n\r\n") {
                    break at + 4;
                }
            };
            let head = String::from_utf8_lossy(&request[..head_end]).to_ascii_lowercase();
            let length = head
                .lines()
                .find_map(|line| line.strip_prefix("content-length: "))
                .map_or(0, |value| value.trim().parse::<usize>().unwrap());
            while request.len() < head_end + length {
                let size = stream.read(&mut buffer).await.unwrap();
                request.extend_from_slice(&buffer[..size]);
            }
            seen.lock().unwrap().push(String::from_utf8_lossy(&request).into_owned());
            let matches = |route: &&'static str| head.starts_with(&route.to_ascii_lowercase());
            let at = routes
                .iter()
                .position(|(route, _, _)| matches(route))
                .unwrap_or_else(|| panic!("unexpected request: {head}"));
            let again = routes[at + 1..].iter().any(|(route, _, _)| matches(route));
            let (_, status, body) = if again { routes.remove(at) } else { routes[at].clone() };
            let response = format!(
                "HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            );
            stream.write_all(response.as_bytes()).await.unwrap();
        }
    });
    (address, task, log)
}

fn sync_at(base_url: String, root: &Path) -> ArtifactsSync {
    let config = ArtifactsSyncConfig { enabled: true, base_url, ..Default::default() };
    let mut sync = ArtifactsSync::new(config, Some("fixture-token".into())).unwrap().unwrap();
    sync.roots = vec![SyncRoot {
        local: root.to_path_buf(),
        remote_prefix: "memory/codex/".into(),
        anchor: root.parent().unwrap().to_path_buf(),
    }];
    sync
}

/// A pull replaces only what this machine last synced: an edit the server has not taken yet
/// (its upload failed, or it was made during the pass) is kept for the next pass to send.
#[tokio::test]
async fn pull_keeps_a_local_edit_the_server_has_not_taken() {
    let list = json!({"headSha":"h1","items":[{"path":"memory/codex/edited.md"},{"path":"memory/codex/synced.md"},{"path":"memory/codex/new.md"}]}).to_string();
    let (url, server) = serve(vec![
        ("GET /v1/artifacts?", "200 OK", list.clone()),
        ("GET /v1/artifacts ", "200 OK", list),
        ("GET /v1/artifacts/file", "200 OK", "remote".into()),
    ]);
    let dir = tempfile::tempdir().unwrap();
    fs::write(dir.path().join("edited.md"), "local edit").unwrap();
    fs::write(dir.path().join("synced.md"), "old").unwrap();
    let mut sync = sync_at(url, dir.path());
    sync.mark("memory/codex/edited.md".into(), b"old".to_vec(), None);
    sync.mark("memory/codex/synced.md".into(), b"old".to_vec(), None);
    let report = sync.pull_once().await.unwrap();
    server.abort();
    assert_eq!(fs::read_to_string(dir.path().join("edited.md")).unwrap(), "local edit");
    assert_eq!(fs::read_to_string(dir.path().join("synced.md")).unwrap(), "remote");
    assert_eq!(fs::read_to_string(dir.path().join("new.md")).unwrap(), "remote");
    assert_eq!((report.pulled, report.conflicts), (2, 1));
    assert_eq!(sync.state.base["memory/codex/edited.md"], b"old", "the edit is still unsent");
}

/// After a save conflict, a remote read that fails fails the pass: read as empty, it merged
/// an unchanged memory to an empty file and truncated it.
#[tokio::test]
async fn a_failed_conflict_read_never_empties_a_memory() {
    let (url, server) = serve(vec![
        ("POST /v1/artifacts/save", "409 Conflict", json!({"currentHeadSha":"h2"}).to_string()),
        ("GET /v1/artifacts/file", "500 Internal Server Error", "{}".into()),
    ]);
    let dir = tempfile::tempdir().unwrap();
    fs::write(dir.path().join("a.md"), "keep me\n").unwrap();
    let mut sync = sync_at(url, dir.path());
    sync.mark("memory/codex/a.md".into(), b"keep me\n".to_vec(), None);
    let files = vec![("memory/codex/a.md".to_owned(), b"keep me\n".to_vec())];
    assert!(sync.push_batch(files, &Trailers::default()).await.is_err());
    server.abort();
    assert_eq!(fs::read_to_string(dir.path().join("a.md")).unwrap(), "keep me\n");
}

/// A conflict retry that fails records nothing as synced and changes no local file, so the
/// pull after it cannot replace the merge and the next pass sends the edit again.
#[tokio::test]
async fn a_failed_conflict_retry_keeps_the_local_edit_unsynced() {
    let conflict = json!({"currentHeadSha":"h2"}).to_string();
    let (url, server) = serve(vec![
        ("POST /v1/artifacts/save", "409 Conflict", conflict.clone()),
        ("POST /v1/artifacts/save", "409 Conflict", conflict),
        ("GET /v1/artifacts/file", "200 OK", "remote\n".into()),
    ]);
    let dir = tempfile::tempdir().unwrap();
    fs::write(dir.path().join("a.md"), "local\n").unwrap();
    let mut sync = sync_at(url, dir.path());
    sync.mark("memory/codex/a.md".into(), b"base\n".to_vec(), None);
    let files = vec![("memory/codex/a.md".to_owned(), b"local\n".to_vec())];
    assert!(sync.push_batch(files, &Trailers::default()).await.is_err());
    server.abort();
    assert_eq!(sync.state.base["memory/codex/a.md"], b"base\n");
    assert_eq!(fs::read_to_string(dir.path().join("a.md")).unwrap(), "local\n");
}

/// A binary file changed on both sides: ours goes beside it as a conflict copy, and the
/// original takes the remote bytes as synced, so the next pass never sends ours over theirs.
#[tokio::test]
async fn a_binary_conflict_keeps_both_versions() {
    let (url, server) = serve(vec![
        ("POST /v1/artifacts/save", "409 Conflict", json!({"currentHeadSha":"h2"}).to_string()),
        (
            "POST /v1/artifacts/save",
            "200 OK",
            json!({"headSha":"h3","commit":{"sha":"c3"}}).to_string(),
        ),
        ("GET /v1/artifacts/file", "200 OK", "theirs".into()),
    ]);
    let dir = tempfile::tempdir().unwrap();
    fs::write(dir.path().join("data.bin"), "ours").unwrap();
    let mut sync = sync_at(url, dir.path());
    sync.mark("memory/codex/data.bin".into(), b"old".to_vec(), None);
    let files = vec![("memory/codex/data.bin".to_owned(), b"ours".to_vec())];
    sync.push_batch(files, &Trailers::default()).await.unwrap();
    server.abort();
    assert_eq!(sync.state.head_sha.as_deref(), Some("h3"));
    assert_eq!(sync.state.base["memory/codex/data.bin"], b"theirs");
    assert_eq!(fs::read_to_string(dir.path().join("data.bin")).unwrap(), "theirs");
    let copies: Vec<_> = fs::read_dir(dir.path())
        .unwrap()
        .map(|entry| entry.unwrap().file_name().into_string().unwrap())
        .filter(|name| name.starts_with("data.conflict-"))
        .collect();
    assert_eq!(copies.len(), 1, "{copies:?}");
    assert_eq!(fs::read_to_string(dir.path().join(&copies[0])).unwrap(), "ours");
    assert_eq!(sync.state.base[&format!("memory/codex/{}", copies[0])], b"ours");
}

/// A file deleted here is deleted on the server, and a pull never brings it back while the
/// server still has the version this machine synced (the delete failed, or is in flight).
#[tokio::test]
async fn a_local_delete_is_sent_and_never_restored() {
    let listed = json!({"headSha":"h2","items":[{"path":"memory/codex/gone.md","commit":"c1"}]});
    let (url, server, log) = serve_recording(vec![
        ("POST /v1/artifacts/save", "409 Conflict", json!({"currentHeadSha":"h2"}).to_string()),
        (
            "POST /v1/artifacts/save",
            "200 OK",
            json!({"headSha":"h3","commit":{"sha":"c3"}}).to_string(),
        ),
        ("GET /v1/artifacts?", "200 OK", listed.to_string()),
        ("GET /v1/artifacts?", "200 OK", json!({"headSha":"h3","items":[]}).to_string()),
    ]);
    let dir = tempfile::tempdir().unwrap();
    let mut sync = sync_at(url, dir.path());
    sync.state.head_sha = Some("h1".into());
    sync.mark("memory/codex/gone.md".into(), b"old".to_vec(), Some("c1".into()));
    // The delete meets a concurrent save: it fails, and the pull leaves the file deleted.
    assert!(sync.sync_once(Trailers::default()).await.is_err());
    sync.pull_once().await.unwrap();
    assert!(!dir.path().join("gone.md").exists());
    assert!(sync.state.synced.contains_key("memory/codex/gone.md"));
    // The next pass sends it at the new head.
    assert_eq!(sync.sync_once(Trailers::default()).await.unwrap().deleted, 1);
    sync.pull_once().await.unwrap();
    server.abort();
    assert!(!dir.path().join("gone.md").exists());
    assert!(sync.state.synced.is_empty());
    let saves: Vec<_> =
        log.lock().unwrap().iter().filter(|r| r.starts_with("POST")).cloned().collect();
    assert!(
        saves.iter().all(|r| r.contains(r#""op":"delete""#) && r.contains("memory/codex/gone.md"))
    );
    assert!(saves[1].contains(r#""expectedHeadSha":"h2""#), "{}", saves[1]);
}

/// A file deleted here but changed on the server since comes back: their edit wins.
#[tokio::test]
async fn a_remote_edit_wins_over_a_local_delete() {
    let listed = json!({"headSha":"h2","items":[{"path":"memory/codex/a.md","commit":"c9"}]});
    let (url, server) = serve(vec![
        ("GET /v1/artifacts?", "200 OK", listed.to_string()),
        ("GET /v1/artifacts/file", "200 OK", "theirs".into()),
    ]);
    let dir = tempfile::tempdir().unwrap();
    let mut sync = sync_at(url, dir.path());
    sync.mark("memory/codex/a.md".into(), b"old".to_vec(), Some("c1".into()));
    sync.pull_once().await.unwrap();
    server.abort();
    assert_eq!(fs::read_to_string(dir.path().join("a.md")).unwrap(), "theirs");
    assert_eq!(sync.state.synced["memory/codex/a.md"].commit.as_deref(), Some("c9"));
}

/// The listing is read page by page to its end; an unchanged commit is not read again, and a
/// head that moves between pages fails the pass instead of mixing two versions.
#[tokio::test]
async fn the_listing_reads_every_page_at_one_head() {
    let (url, server, log) = serve_recording(vec![
        ("GET /v1/artifacts?limit=100 ", "200 OK", json!({"headSha":"h1","items":[{"path":"memory/codex/a.md","commit":"c1"}],"cursor":"memory/codex/a.md"}).to_string()),
        ("GET /v1/artifacts?limit=100&cursor=", "200 OK", json!({"headSha":"h1","items":[{"path":"memory/codex/b.md","commit":"c2"},{"id":"01J0000000000000000000000","path":"artifacts/01J0000000000000000000000","commit":"c2"}]}).to_string()),
        ("GET /v1/artifacts?limit=100 ", "200 OK", json!({"headSha":"h1","items":[],"cursor":"x"}).to_string()),
        ("GET /v1/artifacts?limit=100&cursor=", "200 OK", json!({"headSha":"h2","items":[]}).to_string()),
        ("GET /v1/artifacts/file", "200 OK", "b".into()),
    ]);
    let dir = tempfile::tempdir().unwrap();
    let mut sync = sync_at(url, dir.path());
    fs::write(dir.path().join("a.md"), "a").unwrap();
    sync.mark("memory/codex/a.md".into(), b"a".to_vec(), Some("c1".into()));
    assert_eq!(sync.pull_once().await.unwrap().pulled, 1);
    assert_eq!(fs::read_to_string(dir.path().join("b.md")).unwrap(), "b");
    let reads: Vec<_> = log
        .lock()
        .unwrap()
        .iter()
        .filter(|r| r.starts_with("GET /v1/artifacts/file"))
        .cloned()
        .collect();
    assert_eq!(reads.len(), 1, "a.md's commit is unchanged, the folder item is not a file");
    assert!(reads[0].contains("b.md"));
    assert!(sync.pull_once().await.is_err(), "the head moved between pages");
    server.abort();
}

/// The synced state survives a restart (and is written only when it changed), so a file
/// deleted while the daemon was down is not restored, and nothing synced is sent again.
#[test]
fn synced_state_survives_a_restart() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("state/artifacts-sync-state.json");
    let mut sync = sync_at("http://127.0.0.1:9".into(), dir.path());
    sync.persist_at(path.clone());
    sync.state.head_sha = Some("h1".into());
    sync.mark("memory/codex/a.md".into(), b"a".to_vec(), Some("c1".into()));
    sync.save_state().unwrap();
    let written = fs::metadata(&path).unwrap().modified().unwrap();
    sync.save_state().unwrap();
    assert_eq!(fs::metadata(&path).unwrap().modified().unwrap(), written);
    let mut restarted = sync_at("http://127.0.0.1:9".into(), dir.path());
    restarted.persist_at(path);
    assert_eq!(restarted.state.head_sha.as_deref(), Some("h1"));
    assert_eq!(restarted.state.synced, sync.state.synced);
    assert!(restarted.state.base.is_empty(), "file contents stay out of the state file");
}

/// A folder above the root that is a symlink (`~/.claude/projects/work -> /elsewhere`) leads
/// it out too: no upload from it and no pull into it.
#[cfg(unix)]
#[tokio::test]
async fn a_root_below_a_symlinked_folder_is_not_synced() {
    let home = tempfile::tempdir().unwrap();
    let outside = tempfile::tempdir().unwrap();
    fs::create_dir_all(outside.path().join("memory")).unwrap();
    fs::write(outside.path().join("memory/secret.md"), "private").unwrap();
    fs::create_dir_all(home.path().join(".claude/projects")).unwrap();
    std::os::unix::fs::symlink(outside.path(), home.path().join(".claude/projects/work")).unwrap();
    let config = ArtifactsSyncConfig {
        enabled: true,
        base_url: "http://127.0.0.1:9".into(),
        ..Default::default()
    };
    let mut sync = ArtifactsSync::new(config, Some("fixture-token".into())).unwrap().unwrap();
    sync.roots = vec![SyncRoot {
        local: home.path().join(".claude/projects/work/memory"),
        remote_prefix: "memory/claude/work/".into(),
        anchor: home.path().to_path_buf(),
    }];
    assert!(!sync.roots[0].usable());
    assert!(sync.locate("memory/claude/work/secret.md").is_none());
    // Nothing to send: an upload would reach the server at port 9 and fail.
    assert_eq!(sync.sync_once(Trailers::default()).await.unwrap(), SyncReport::default());
    fs::create_dir_all(home.path().join(".claude/projects/real/memory")).unwrap();
    sync.roots[0].local = home.path().join(".claude/projects/real/memory");
    assert!(sync.roots[0].usable());
}

#[cfg(unix)]
#[test]
fn a_root_that_is_a_symlink_is_not_synced() {
    let dir = tempfile::tempdir().unwrap();
    let outside = tempfile::tempdir().unwrap();
    std::os::unix::fs::symlink(outside.path(), dir.path().join("memories")).unwrap();
    let sync = sync_at("http://127.0.0.1:9".into(), &dir.path().join("memories"));
    assert!(!sync.roots[0].usable());
    assert!(sync.locate("memory/codex/x.md").is_none());
}

/// No read or write goes through a symlink below a root: the walk skips them, a pull into one
/// writes nothing outside, and a file that is a symlink is replaced, not written through.
#[cfg(unix)]
#[test]
fn symlinks_below_a_root_are_never_followed() {
    let dir = tempfile::tempdir().unwrap();
    let outside = tempfile::tempdir().unwrap();
    fs::write(outside.path().join("notes.md"), "elsewhere").unwrap();
    std::os::unix::fs::symlink(outside.path(), dir.path().join("shared")).unwrap();
    std::os::unix::fs::symlink(outside.path().join("notes.md"), dir.path().join("link.md"))
        .unwrap();
    fs::write(dir.path().join("own.md"), "mine").unwrap();
    let sync = sync_at("http://127.0.0.1:9".into(), dir.path());
    let root = sync.roots[0].open().unwrap();
    assert_eq!(root.read_tree().unwrap(), vec![(PathBuf::from("own.md"), b"mine".to_vec())]);
    assert_eq!(root.read(Path::new("shared/notes.md")).unwrap(), None);
    assert!(!root.missing(Path::new("shared/notes.md")), "a symlink in the way is something");
    let (into_link, relative) = sync.locate("memory/codex/shared/notes.md").unwrap();
    assert!(!replace_if_unchanged(&into_link, &relative, None, b"pulled").unwrap());
    let (over_link, relative) = sync.locate("memory/codex/link.md").unwrap();
    assert!(!replace_if_unchanged(&over_link, &relative, None, b"pulled").unwrap());
    assert_eq!(fs::read_to_string(outside.path().join("notes.md")).unwrap(), "elsewhere");
    assert_eq!(fs::read_dir(outside.path()).unwrap().count(), 1);
}

/// A folder checked when the root opened and then swapped for a symlink (another process, mid
/// pass) leads nowhere: the write goes through the folder that was opened, or fails.
#[cfg(unix)]
#[test]
fn a_folder_swapped_for_a_symlink_mid_pass_leads_nowhere() {
    let home = tempfile::tempdir().unwrap();
    let outside = tempfile::tempdir().unwrap();
    fs::create_dir_all(home.path().join("memories/notes")).unwrap();
    let mut sync = sync_at("http://127.0.0.1:9".into(), &home.path().join("memories"));
    sync.roots[0].anchor = home.path().to_path_buf();
    let (dir, relative) = sync.locate("memory/codex/notes/a.md").unwrap();
    // The root is open; now its folder becomes a symlink to somewhere else.
    fs::rename(home.path().join("memories"), home.path().join("moved")).unwrap();
    std::os::unix::fs::symlink(outside.path(), home.path().join("memories")).unwrap();
    assert!(replace_if_unchanged(&dir, &relative, None, b"pulled").unwrap());
    assert_eq!(fs::read_dir(outside.path()).unwrap().count(), 0, "nothing outside the root");
    assert_eq!(fs::read_to_string(home.path().join("moved/notes/a.md")).unwrap(), "pulled");
    // A subfolder swapped the same way is refused, never followed.
    fs::rename(home.path().join("moved/notes"), home.path().join("moved/notes-old")).unwrap();
    std::os::unix::fs::symlink(outside.path(), home.path().join("moved/notes")).unwrap();
    assert!(!replace_if_unchanged(&dir, &relative, None, b"again").unwrap());
    assert!(dir.write(&relative, b"again").is_err());
    assert_eq!(fs::read_dir(outside.path()).unwrap().count(), 0, "nothing outside the root");
}

#[test]
fn a_remote_path_never_maps_outside_its_root() {
    let config = ArtifactsSyncConfig { enabled: true, ..Default::default() };
    let mut sync = ArtifactsSync::new(config, None).unwrap().unwrap();
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().to_path_buf();
    sync.roots = vec![SyncRoot {
        local: root.clone(),
        remote_prefix: "memory/codex/".into(),
        anchor: root.parent().unwrap().to_path_buf(),
    }];
    assert_eq!(sync.local_for_remote("memory/codex/notes/a.md"), Some(root.join("notes/a.md")));
    for path in [
        "memory/codex/../../.ssh/authorized_keys",
        "memory/codex/a/../../b",
        "memory/codex//etc/passwd",
        "memory/codex/./a",
        "memory/codex/a\\..\\b",
        "memory/codex/",
        "memory/other/a.md",
    ] {
        assert_eq!(sync.local_for_remote(path), None, "{path}");
    }
}

/// The save body uses the platform's field names (`ArtifactSave`, `ArtifactChange` in
/// cmux-platform's src/api/Artifacts.ts): snake_case keys reached the server as no content.
#[test]
fn a_save_request_uses_the_platform_field_names() {
    let request = SaveRequest {
        expected_head_sha: Some("h1".into()),
        branch: "main",
        message: "m".into(),
        trailers: Trailers::default(),
        changes: vec![Change {
            path: "memory/codex/a.md".into(),
            op: "put",
            content_base64: Some("YQ==".into()),
            blob_sha256: Some("0".repeat(64)),
            content_type: Some("text/markdown".into()),
        }],
    };
    let body = serde_json::to_value(&request).unwrap();
    assert_eq!(
        body,
        json!({"expectedHeadSha":"h1","branch":"main","message":"m","trailers":{},"changes":[{"path":"memory/codex/a.md","op":"put","contentBase64":"YQ==","blobSha256":"0".repeat(64),"contentType":"text/markdown"}]})
    );
}

#[test]
fn disabled_is_inert() {
    let config = ArtifactsSyncConfig::default();
    assert!(ArtifactsSync::new(config, Some("secret".into())).unwrap().is_none());
}

#[test]
fn secret_paths_and_content_are_skipped() {
    assert!(should_skip("memory/claude/scope/.env", b"x"));
    assert!(should_skip("memory/claude/scope/server.pem", b"x"));
    assert!(should_skip("memory/claude/scope/notes.md", b"AWS_SECRET_ACCESS_KEY=abc"));
    assert!(!should_skip("memory/claude/scope/notes.md", b"safe notes"));
    for text in [
        "password: hunter22",
        "password: x",
        "apiKey: 9f8e7d6c5b4a",
        "access_token: abcd1234efgh",
        "client_secret = \"s3cr3tvalue\"",
        "-----BEGIN EC PRIVATE KEY-----",
    ] {
        assert!(should_skip("memory/codex/notes.md", text.as_bytes()), "{text}");
    }
    assert!(!should_skip("memory/codex/notes.md", b"Rotate the password every quarter."));
}

#[test]
fn markdown_three_way_merge_keeps_non_overlapping_edits() {
    let merged = merge_markdown(b"one\ntwo\n", b"ONE\ntwo\n", b"one\nTWO\n");
    assert_eq!(String::from_utf8(merged).unwrap(), "ONE\nTWO\n");
}

#[test]
fn markdown_conflict_is_explicit() {
    let merged = String::from_utf8(merge_markdown(b"one\n", b"local\n", b"remote\n")).unwrap();
    assert!(merged.contains("<<<<<<< local"));
    assert!(merged.contains(">>>>>>> remote"));
}

#[test]
fn sha256_matches_contract_blob_hash() {
    assert_eq!(
        sha256(b"hello"),
        "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
    );
}

/// Each tick takes the token current at that tick, and a 401 makes the next tick ask for a
/// new one: a token taken once at start would be sent after it expired, forever.
#[tokio::test]
async fn every_tick_takes_a_current_token_and_a_refusal_asks_for_a_new_one() {
    use std::sync::Mutex;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let seen = Arc::new(Mutex::new(Vec::<String>::new()));
    let server = tokio::spawn({
        let seen = Arc::clone(&seen);
        async move {
            for status in ["401 Unauthorized", "200 OK"] {
                let (mut stream, _) = listener.accept().await.unwrap();
                let mut request = Vec::new();
                while !request.windows(4).any(|bytes| bytes == b"\r\n\r\n") {
                    let mut buffer = [0; 1024];
                    let size = stream.read(&mut buffer).await.unwrap();
                    assert!(size > 0 && request.len() < 8192);
                    request.extend_from_slice(&buffer[..size]);
                }
                let request = String::from_utf8(request).unwrap().to_ascii_lowercase();
                assert!(request.starts_with("get /v1/artifacts?"), "{request}");
                let bearer = request
                    .lines()
                    .find_map(|line| line.strip_prefix("authorization: bearer "))
                    .unwrap();
                seen.lock().unwrap().push(bearer.trim().to_owned());
                let body = r#"{"headSha":null,"items":[]}"#;
                let response = format!(
                    "HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                    body.len()
                );
                stream.write_all(response.as_bytes()).await.unwrap();
            }
        }
    });
    let config = ArtifactsSyncConfig {
        enabled: true,
        base_url: format!("http://{address}"),
        ..Default::default()
    };
    let mut sync = ArtifactsSync::new(config, None).unwrap().unwrap();
    sync.roots.clear(); // no local files: each tick is the pull's one request
    let asked = Arc::new(Mutex::new(Vec::<bool>::new()));
    let mut fresh = false;
    for _ in 0..2 {
        let asked = Arc::clone(&asked);
        let token = move |fresh: bool| async move {
            let mut asked = asked.lock().unwrap();
            asked.push(fresh);
            Ok(format!("token-{}", asked.len()))
        };
        fresh = tokio::time::timeout(
            std::time::Duration::from_secs(5),
            sync_tick(&mut sync, token, fresh, &Trailers::default()),
        )
        .await
        .unwrap();
    }
    server.await.unwrap();
    assert_eq!(*asked.lock().unwrap(), [false, true]);
    assert_eq!(*seen.lock().unwrap(), ["token-1", "token-2"]);
    assert!(!fresh, "a pass the server accepted keeps the held token");
}

#[test]
fn config_round_trip_keeps_disabled_default_omitted() {
    let config = ArtifactsSyncConfig::default();
    assert_eq!(serde_json::to_value(&config).unwrap()["enabled"], json!(false));
}
