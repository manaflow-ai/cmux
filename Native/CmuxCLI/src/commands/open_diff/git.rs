use crate::{CliError, Result};
use serde_json::{json, Value};
use std::{
    collections::HashSet,
    env, fs,
    io::Read,
    path::{Path, PathBuf},
    process::{Command, Stdio},
    time::{Duration, Instant},
};

pub fn capture(
    program: &str,
    args: &[&str],
    cwd: &str,
    timeout: Duration,
    allow_diff: bool,
) -> Result<Vec<u8>> {
    let mut child = Command::new(program)
        .args(args)
        .current_dir(cwd)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()?;
    let mut stdout = child.stdout.take().unwrap();
    let mut stderr = child.stderr.take().unwrap();
    let out = std::thread::spawn(move || {
        let mut data = Vec::new();
        stdout.read_to_end(&mut data).map(|_| data)
    });
    let err = std::thread::spawn(move || {
        let mut data = Vec::new();
        stderr.read_to_end(&mut data).map(|_| data)
    });
    let deadline = Instant::now() + timeout;
    let status = loop {
        match child.try_wait()? {
            Some(s) => break s,
            None if Instant::now() < deadline => std::thread::sleep(Duration::from_millis(10)),
            None => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(CliError::new(
                    "process.timeout",
                    format!("{program} timed out"),
                ));
            }
        }
    };
    let data = out
        .join()
        .map_err(|_| CliError::new("process.read", "Failed to read process output"))??;
    let errors = err
        .join()
        .map_err(|_| CliError::new("process.read", "Failed to read process output"))??;
    if !status.success() && !(allow_diff && status.code() == Some(1)) {
        return Err(CliError::new(
            "git.failed",
            format!(
                "{program} {} failed with status {}: {}",
                args.join(" "),
                status.code().unwrap_or(-1),
                String::from_utf8_lossy(&errors).trim()
            ),
        ));
    }
    Ok(data)
}
pub fn run(repo: &str, args: &[&str]) -> Result<String> {
    let data = capture("git", args, repo, Duration::from_secs(60), false)?;
    String::from_utf8(data)
        .map_err(|_| CliError::new("git.encoding", "Git output is not valid UTF-8"))
}
pub fn root(cwd: &str) -> Result<String> {
    run(cwd, &["rev-parse", "--show-toplevel"])
        .map(|v| v.trim().to_owned())
        .map_err(|_| CliError::new("git.repo", "cmux diff git sources require a git repository"))
}
fn exists(repo: &str, reference: &str) -> bool {
    !reference.starts_with('-')
        && run(
            repo,
            &[
                "rev-parse",
                "--verify",
                "--quiet",
                &format!("{reference}^{{commit}}"),
            ],
        )
        .is_ok()
}
fn default_base(repo: &str) -> Result<String> {
    if let Ok(v) = run(
        repo,
        &[
            "symbolic-ref",
            "--quiet",
            "--short",
            "refs/remotes/origin/HEAD",
        ],
    ) {
        if !v.trim().is_empty() {
            return Ok(v.trim().into());
        }
    }
    for candidate in [
        "origin/main",
        "origin/master",
        "upstream/main",
        "upstream/master",
        "main",
        "master",
    ] {
        if exists(repo, candidate) {
            return Ok(candidate.into());
        }
    }
    if let Ok(v) = run(
        repo,
        &[
            "rev-parse",
            "--abbrev-ref",
            "--symbolic-full-name",
            "@{upstream}",
        ],
    ) {
        if !v.trim().is_empty() {
            return Ok(v.trim().into());
        }
    }
    Err(CliError::new(
        "git.base",
        "Couldn't find a branch diff base. Set an upstream branch or create origin/main.",
    ))
}
fn pr_base(repo: &str) -> Option<String> {
    let data = capture(
        "gh",
        &[
            "pr",
            "view",
            "--json",
            "baseRefName",
            "--jq",
            ".baseRefName",
        ],
        repo,
        Duration::from_secs(4),
        false,
    )
    .ok()?;
    let base = String::from_utf8(data).ok()?.trim().to_owned();
    if base.is_empty() {
        return None;
    }
    [format!("origin/{base}"), base]
        .into_iter()
        .find(|reference| exists(repo, reference))
}
pub fn branch_base(repo: &str, explicit: Option<&str>) -> Result<(String, String, String)> {
    if let Some(base) = explicit.filter(|v| !v.trim().is_empty()) {
        let base = base.trim();
        if !exists(repo, base) {
            return Err(CliError::new(
                "git.base",
                format!("Branch diff base not found in repository: {base}"),
            ));
        }
        return Ok((base.into(), "manual".into(), "high".into()));
    }
    let branch = run(repo, &["rev-parse", "--abbrev-ref", "HEAD"])
        .ok()
        .map(|v| v.trim().to_owned())
        .filter(|v| v != "HEAD");
    if let Some(branch) = &branch {
        if let Ok(recorded) = run(
            repo,
            &["config", "--get", &format!("branch.{branch}.cmuxBase")],
        ) {
            let reference = recorded.trim();
            if exists(repo, reference) {
                return Ok((reference.into(), "created from".into(), "high".into()));
            }
        }
    }
    if let Some(reference) = pr_base(repo) {
        return Ok((reference, "PR base".into(), "high".into()));
    }
    if let Some(branch) = branch {
        if let Ok(upstream) = run(
            repo,
            &[
                "rev-parse",
                "--abbrev-ref",
                "--symbolic-full-name",
                "@{upstream}",
            ],
        ) {
            let reference = upstream.trim();
            if reference.split_once('/').map(|(_, name)| name) != Some(branch.as_str())
                && exists(repo, reference)
            {
                return Ok((reference.into(), "fork point".into(), "high".into()));
            }
        }
    }
    Ok((default_base(repo)?, "default".into(), "low".into()))
}
fn patch(repo: &str, tail: &[&str], no_index: bool) -> Result<String> {
    let mut args = vec!["diff", "--no-ext-diff", "--no-color", "--binary"];
    args.extend_from_slice(tail);
    let data = capture("git", &args, repo, Duration::from_secs(60), no_index)?;
    String::from_utf8(data)
        .map_err(|_| CliError::new("patch.encoding", "Diff input is not valid UTF-8"))
}
pub fn read_git_patch(
    source: &str,
    cwd: &str,
    base: Option<&str>,
    session: Option<&str>,
    workspace: Option<&str>,
    surface: Option<&str>,
) -> Result<String> {
    let repo = root(cwd)?;
    match source {
        "unstaged" => patch(&repo, &["--"], false),
        "staged" => patch(&repo, &["--cached", "--"], false),
        "branch" => {
            let base = branch_base(&repo, base)?.0;
            let merge = run(&repo, &["merge-base", "HEAD", &base])?;
            patch(&repo, &[merge.trim(), "--"], false)
        }
        "last-turn" => {
            let (Some(workspace), Some(surface)) = (workspace, surface) else {
                return Err(CliError::usage("cmux diff --last-turn requires a workspace and surface context. Run it from a cmux terminal or pass --workspace and --surface."));
            };
            let home = env::var("HOME").unwrap_or_default();
            let state = env::var("CMUX_AGENT_HOOK_STATE_DIR")
                .map(|v| PathBuf::from(super::resolve_path(&v)))
                .unwrap_or_else(|_| PathBuf::from(home).join(".cmuxterm"));
            read_last_turn(&repo, &state, workspace, surface, session)
        }
        _ => Err(CliError::usage("Unknown git diff source")),
    }
}
fn scope_matches(a: &str, b: &str) -> bool {
    match (uuid::Uuid::parse_str(a), uuid::Uuid::parse_str(b)) {
        (Ok(a), Ok(b)) => a == b,
        _ => a == b,
    }
}
fn read_last_turn(
    repo: &str,
    state: &Path,
    workspace: &str,
    surface: &str,
    session: Option<&str>,
) -> Result<String> {
    let path = state.join("agent-turn-diff-baselines.json");
    if !path.exists() {
        return Ok(String::new());
    }
    let store: Value = serde_json::from_slice(&fs::read(path)?)?;
    let canonical = fs::canonicalize(repo)?;
    let record = store["records"].as_array().and_then(|records| {
        records
            .iter()
            .filter(|r| {
                r["repoRoot"]
                    .as_str()
                    .and_then(|v| fs::canonicalize(v).ok())
                    .as_ref()
                    == Some(&canonical)
                    && scope_matches(r["workspaceId"].as_str().unwrap_or(""), workspace)
                    && scope_matches(r["surfaceId"].as_str().unwrap_or(""), surface)
                    && session.is_none_or(|s| r["sessionId"].as_str() == Some(s))
            })
            .max_by(|a, b| {
                a["capturedAt"]
                    .as_f64()
                    .unwrap_or(0.0)
                    .total_cmp(&b["capturedAt"].as_f64().unwrap_or(0.0))
            })
    });
    let Some(record) = record else {
        return Ok(String::new());
    };
    let base = record["baseCommit"]
        .as_str()
        .ok_or_else(|| CliError::new("diff.baseline", "Invalid last-turn baseline"))?;
    if base.starts_with('-') {
        return Err(CliError::new("diff.baseline", "Invalid last-turn baseline"));
    }
    run(repo, &["cat-file", "-e", &format!("{base}^{{tree}}")])?;
    let mut patches = vec![patch(repo, &[base, "--"], false)?];
    patches.extend(untracked(repo, state, record)?);
    Ok(join_patches(patches))
}
fn safe_relative(path: &str) -> bool {
    !path.starts_with('/')
        && !path.is_empty()
        && path
            .split('/')
            .all(|part| !part.is_empty() && part != "." && part != "..")
}
fn safe_repo_file(repo: &str, path: &str) -> Option<PathBuf> {
    if !safe_relative(path) {
        return None;
    }
    let root = fs::canonicalize(repo).ok()?;
    let joined = root.join(path);
    if joined.exists() {
        let canonical = fs::canonicalize(&joined).ok()?;
        if !canonical.starts_with(&root) {
            return None;
        }
        Some(canonical)
    } else {
        Some(joined)
    }
}
fn baseline_content(
    repo: &str,
    state: &Path,
    record: &Value,
    path: &str,
    hash: &str,
) -> Option<Vec<u8>> {
    if !safe_relative(path) {
        return None;
    }
    if let Some(id) = record["untrackedSnapshotId"]
        .as_str()
        .filter(|id| uuid::Uuid::parse_str(id).is_ok())
    {
        let root = state
            .join("agent-turn-diff-baseline-snapshots")
            .join(id)
            .join("files");
        if let (Ok(root), Ok(file)) = (fs::canonicalize(&root), fs::canonicalize(root.join(path))) {
            if file.starts_with(root) {
                if let Ok(bytes) = fs::read(file) {
                    return Some(bytes);
                }
            }
        }
    }
    if hash.is_empty() || !hash.bytes().all(|v| v.is_ascii_hexdigit()) {
        return None;
    }
    capture(
        "git",
        &["cat-file", "blob", hash],
        repo,
        Duration::from_secs(30),
        false,
    )
    .ok()
}
fn untracked(repo: &str, state: &Path, record: &Value) -> Result<Vec<String>> {
    let baseline = record["untrackedPaths"]
        .as_array()
        .map(|a| a.iter().filter_map(Value::as_str).collect::<HashSet<_>>())
        .unwrap_or_default();
    let current = run(repo, &["ls-files", "--others", "--exclude-standard", "-z"])?;
    let paths = current
        .split('\0')
        .filter(|v| !v.is_empty())
        .collect::<Vec<_>>();
    let mut result = Vec::new();
    for path in &paths {
        let Some(current) = safe_repo_file(repo, path) else {
            continue;
        };
        if !baseline.contains(path) {
            result.push(patch(repo, &["--no-index", "--", "/dev/null", path], true)?);
            continue;
        }
        let Some(hash) = record["untrackedPathHashes"][*path].as_str() else {
            continue;
        };
        if run(repo, &["hash-object", "--no-filters", "--", path])?.trim() == hash {
            continue;
        }
        let Some(bytes) = baseline_content(repo, state, record, path, hash) else {
            continue;
        };
        let temp = Temporary::new()?;
        let old = temp.0.join("baseline").join(path);
        let new = temp.0.join("current").join(path);
        fs::create_dir_all(old.parent().unwrap())?;
        fs::create_dir_all(new.parent().unwrap())?;
        fs::write(old, bytes)?;
        fs::copy(current, new)?;
        let patch = patch(
            &temp.0.to_string_lossy(),
            &[
                "--no-index",
                "--",
                &format!("baseline/{path}"),
                &format!("current/{path}"),
            ],
            true,
        )?;
        result.push(
            patch
                .lines()
                .map(|line| {
                    if line.starts_with("diff --git ") {
                        line.replacen("a/baseline/", "a/", 1)
                            .replacen("b/current/", "b/", 1)
                    } else if line.starts_with("--- ") {
                        line.replacen("a/baseline/", "a/", 1)
                    } else if line.starts_with("+++ ") {
                        line.replacen("b/current/", "b/", 1)
                    } else {
                        line.into()
                    }
                })
                .collect::<Vec<_>>()
                .join("\n")
                + "\n",
        );
    }
    let current_set = paths.iter().copied().collect::<HashSet<_>>();
    let mut deleted = baseline
        .difference(&current_set)
        .copied()
        .collect::<Vec<_>>();
    deleted.sort();
    for path in deleted {
        let Some(current) = safe_repo_file(repo, path) else {
            continue;
        };
        if current.exists() {
            continue;
        }
        let Some(hash) = record["untrackedPathHashes"][path].as_str() else {
            continue;
        };
        let Some(bytes) = baseline_content(repo, state, record, path, hash) else {
            continue;
        };
        let temp = Temporary::new()?;
        let old = temp.0.join(path);
        fs::create_dir_all(old.parent().unwrap())?;
        fs::write(old, bytes)?;
        result.push(patch(
            &temp.0.to_string_lossy(),
            &["--no-index", "--", path, "/dev/null"],
            true,
        )?);
    }
    Ok(result)
}
struct Temporary(PathBuf);
impl Temporary {
    fn new() -> Result<Self> {
        let path = env::temp_dir().join(format!("cmux-diff-untracked-{}", uuid::Uuid::new_v4()));
        fs::create_dir(&path)?;
        Ok(Self(path))
    }
}
impl Drop for Temporary {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}
fn join_patches(parts: Vec<String>) -> String {
    parts
        .into_iter()
        .filter(|s| !s.trim().is_empty())
        .map(|s| if s.ends_with('\n') { s } else { s + "\n" })
        .collect()
}

pub fn branch_groups(repo: &str, base: Option<&str>, suggested_only: bool) -> Result<Value> {
    let current = run(repo, &["rev-parse", "--abbrev-ref", "HEAD"]).unwrap_or_default();
    let current = current.trim();
    let mut suggested = Vec::new();
    let mut seen = HashSet::new();
    let mut add = |base: (String, String, String)| {
        if seen.insert(base.0.clone()) {
            suggested.push(json!({"ref":base.0,"label":base.0,"secondary":base.1,"reason":base.1,"confidence":base.2}));
        }
    };
    if suggested_only {
        if let Ok(value) = branch_base(repo, base) {
            add(value);
        }
    } else {
        if let Some(base) = base.filter(|v| exists(repo, v)) {
            add((base.into(), "manual".into(), "high".into()));
        }
        if let Ok(value) = branch_base(repo, None) {
            add(value);
        }
        if let Ok(recorded) = run(
            repo,
            &["config", "--get", &format!("branch.{current}.cmuxBase")],
        ) {
            let value = recorded.trim();
            if exists(repo, value) {
                add((value.into(), "created from".into(), "high".into()));
            }
        }
        if let Some(value) = pr_base(repo) {
            add((value, "PR base".into(), "high".into()));
        }
    }
    let mut groups = Vec::new();
    if !suggested.is_empty() {
        groups.push(json!({"id":"suggested","label":"Suggested","rows":suggested}));
    }
    if suggested_only {
        return Ok(json!({"groups":groups}));
    }
    let mut worktrees = Vec::new();
    for chunk in run(repo, &["worktree", "list", "--porcelain"])
        .unwrap_or_default()
        .split("\n\n")
    {
        let dir = chunk.lines().find_map(|l| l.strip_prefix("worktree "));
        let reference = chunk
            .lines()
            .find_map(|l| l.strip_prefix("branch refs/heads/"));
        if let (Some(dir), Some(reference)) = (dir, reference) {
            if fs::canonicalize(dir).ok() != fs::canonicalize(repo).ok()
                && !seen.contains(reference)
            {
                let name = Path::new(dir)
                    .file_name()
                    .unwrap_or_default()
                    .to_string_lossy();
                worktrees.push(
                    json!({"ref":reference,"label":reference,"secondary":name,"worktreeDir":name}),
                );
            }
        }
    }
    if !worktrees.is_empty() {
        groups.push(json!({"id":"worktrees","label":"Worktrees","rows":worktrees}));
    }
    for (id, label, namespace) in [
        ("branches", "Branches", "refs/heads"),
        ("remotes", "Remotes", "refs/remotes"),
    ] {
        let listing = run(
            repo,
            &[
                "for-each-ref",
                "--count=5000",
                "--format=%(refname:short)%09%(committerdate:relative)",
                namespace,
            ],
        )
        .unwrap_or_default();
        let rows = listing
            .lines()
            .filter_map(|line| {
                let mut parts = line.split('\t');
                let r = parts.next()?;
                if r.is_empty() || r.ends_with("/HEAD") || seen.contains(r) {
                    return None;
                }
                let mut value = json!({"ref":r,"label":r});
                if id == "branches" {
                    if let Some(date) = parts.next() {
                        value["secondary"] = json!(date);
                    }
                    if r == current {
                        value["current"] = json!(true);
                    }
                }
                Some(value)
            })
            .collect::<Vec<_>>();
        if !rows.is_empty() {
            groups.push(json!({"id":id,"label":label,"rows":rows}));
        }
    }
    let mut recent = Vec::new();
    let mut recent_seen = HashSet::new();
    for line in run(repo, &["reflog", "--format=%gs", "-n", "200"])
        .unwrap_or_default()
        .lines()
    {
        if let Some(reference) = line
            .strip_prefix("checkout: moving from ")
            .and_then(|v| v.rsplit_once(" to ").map(|(_, r)| r))
        {
            if recent.len() < 8
                && !seen.contains(reference)
                && recent_seen.insert(reference)
                && exists(repo, reference)
            {
                recent.push(json!({"ref":reference,"label":reference}));
            }
        }
    }
    if !recent.is_empty() {
        groups.push(json!({"id":"recent","label":"Recent","rows":recent}));
    }
    Ok(json!({"groups":groups}))
}

#[cfg(test)]
mod tests {
    use super::*;
    fn fixture() -> tempfile::TempDir {
        let dir = tempfile::tempdir().unwrap();
        let r = dir.path().to_str().unwrap();
        run(r, &["init", "-b", "main"]).unwrap();
        run(r, &["config", "user.email", "test@example.com"]).unwrap();
        run(r, &["config", "user.name", "Test"]).unwrap();
        fs::write(dir.path().join("file"), "before\n").unwrap();
        run(r, &["add", "file"]).unwrap();
        run(r, &["commit", "-m", "initial"]).unwrap();
        dir
    }
    #[test]
    fn branch_base_preserves_recorded_creation_base() {
        let dir = fixture();
        let repo = dir.path().to_str().unwrap();
        run(repo, &["checkout", "-b", "feature/nested"]).unwrap();
        run(repo, &["config", "branch.feature/nested.cmuxBase", "main"]).unwrap();
        assert_eq!(
            branch_base(repo, None).unwrap(),
            ("main".into(), "created from".into(), "high".into())
        );
    }
    #[test]
    fn last_turn_snapshot_includes_changed_added_and_deleted_untracked() {
        let dir = fixture();
        let repo = dir.path().to_str().unwrap();
        let state = tempfile::tempdir().unwrap();
        let id = uuid::Uuid::new_v4().to_string();
        let snapshot = state
            .path()
            .join("agent-turn-diff-baseline-snapshots")
            .join(&id)
            .join("files");
        fs::create_dir_all(&snapshot).unwrap();
        fs::write(snapshot.join("changed"), "old\n").unwrap();
        fs::write(snapshot.join("deleted"), "gone\n").unwrap();
        let hash = run(
            repo,
            &[
                "hash-object",
                "--no-filters",
                snapshot.join("changed").to_str().unwrap(),
            ],
        )
        .unwrap();
        let deleted = run(
            repo,
            &[
                "hash-object",
                "--no-filters",
                snapshot.join("deleted").to_str().unwrap(),
            ],
        )
        .unwrap();
        let head = run(repo, &["rev-parse", "HEAD"]).unwrap();
        let record = json!({"workspaceId":"workspace","surfaceId":"surface","sessionId":"session","repoRoot":repo,"baseCommit":head.trim(),"capturedAt":1,"untrackedPaths":["changed","deleted"],"untrackedPathHashes":{"changed":hash.trim(),"deleted":deleted.trim()},"untrackedSnapshotId":id});
        fs::write(
            state.path().join("agent-turn-diff-baselines.json"),
            json!({"version":1,"records":[record]}).to_string(),
        )
        .unwrap();
        fs::write(dir.path().join("changed"), "new\n").unwrap();
        fs::write(dir.path().join("added"), "added\n").unwrap();
        let patch =
            read_last_turn(repo, state.path(), "workspace", "surface", Some("session")).unwrap();
        assert!(patch.contains("-old\n+new"));
        assert!(patch.contains("+added"));
        assert!(patch.contains("-gone"));
        assert!(!patch.contains("a/baseline/"));
        assert!(
            read_last_turn(repo, state.path(), "workspace", "other", None)
                .unwrap()
                .is_empty()
        );
    }
    #[test]
    fn traversal_and_option_refs_are_rejected() {
        assert!(!safe_relative("../file"));
        assert!(!safe_relative("/tmp/file"));
        assert!(!safe_relative("a//b"));
        let dir = fixture();
        assert!(!exists(dir.path().to_str().unwrap(), "--all"));
    }
}
