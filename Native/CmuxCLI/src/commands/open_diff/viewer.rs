//! Publishes the existing React diff viewer and its capability-bound asset manifest.
//! The app's `cmuxDiff` WebKit bridge drives the bundled Rust sidecar on demand.
use crate::{CliError, Context, Result};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    env, fs,
    io::Write,
    os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt},
    path::{Path, PathBuf},
};

pub struct Viewer {
    pub path: PathBuf,
    pub url: String,
    pub token: String,
    pub files: Vec<Value>,
}
pub struct Input<'a> {
    pub title: &'a str,
    pub layout: &'a str,
    pub layout_source: &'a str,
    pub font_size: Option<f64>,
    pub patch: &'a str,
    pub source_label: &'a str,
    pub source: Option<&'a str>,
    pub repo: Option<&'a str>,
    pub base: Option<&'a str>,
    pub workspace: Option<&'a str>,
    pub surface: Option<&'a str>,
    pub external_url: Option<&'a str>,
    pub last_turn_patch: Option<&'a str>,
}

pub fn directory() -> Result<PathBuf> {
    let path = PathBuf::from(format!("/tmp/cmux-diff-viewer-{}", unsafe {
        libc::getuid()
    }));
    match fs::create_dir(&path) {
        Ok(()) => {}
        Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {}
        Err(e) => return Err(e.into()),
    }
    let metadata = fs::symlink_metadata(&path)?;
    if !metadata.is_dir() || metadata.uid() != unsafe { libc::getuid() } {
        return Err(CliError::new(
            "diff.directory",
            "Unsafe diff viewer directory",
        ));
    }
    fs::set_permissions(&path, fs::Permissions::from_mode(0o700))?;
    Ok(fs::canonicalize(path)?)
}

pub fn write(ctx: &Context, input: Input<'_>) -> Result<Viewer> {
    let root = directory()?;
    let token = uuid::Uuid::new_v4().to_string();
    let group = uuid::Uuid::new_v4().to_string();
    let path = root.join(format!("diff-{group}-viewer.html"));
    let patch_path = path.with_extension("patch");
    // The last-turn resource remains stable while typed source changes create
    // their own patches. It must never be overwritten with an unstaged patch.
    atomic_write(
        &patch_path,
        input.last_turn_patch.unwrap_or(input.patch).as_bytes(),
    )?;
    let assets = copy_assets(&root)?;
    let mut files = assets.files;
    files.push(allowed(&root, &patch_path, "text/x-diff")?);
    let appearance = appearance(ctx, input.font_size);
    let mut payload = json!({"patchURL":format!("./{}",patch_path.file_name().unwrap().to_string_lossy()),"title":input.title,"sourceLabel":input.source_label,"layout":input.layout,"layoutSource":input.layout_source,"appearance":appearance,"labels":labels(),"shortcuts":shortcuts(),"sourceOptions":[],"repoOptions":[],"baseOptions":[],"generatedAt":timestamp(),"transport":{"kind":"webKit","endpoint":"cmuxDiff","protocolVersion":1}});
    if let Some(url) = input.external_url {
        payload["externalURL"] = json!(url);
    }
    if let Some(repo) = input.repo {
        payload["repoRoot"] = json!(repo);
    }
    if let Some(source) = input.source {
        let repo = input
            .repo
            .ok_or_else(|| CliError::new("git.repo", "Diff source requires a repository"))?;
        let repos = repo_options(repo);
        let typed = |source: &str, repo: &str| -> Value {
            match source {
                "last-turn" => {
                    json!({"kind":"patch","path":format!("/{}",patch_path.file_name().unwrap().to_string_lossy())})
                }
                "branch" => {
                    let mut v = json!({"kind":"branch","repoRoot":repo});
                    if let Some(base) = input.base {
                        v["baseRef"] = json!(base);
                    }
                    v
                }
                _ => json!({"kind":source,"repoRoot":repo}),
            }
        };
        payload["sessionSource"] = typed(source, repo);
        payload["capabilityToken"] = json!(token);
        if let Some(base) = input.base {
            payload["branchBaseRef"] = json!(base);
        }
        payload["sourceOptions"]=json!([("unstaged","Unstaged"),("staged","Staged"),("branch","Branch"),("last-turn","Last turn")].iter().map(|(kind,label)|json!({"value":kind,"label":label,"selected":*kind==source,"disabled":*kind=="last-turn"&&input.last_turn_patch.is_none(),"sessionSource":typed(kind,repo)})).collect::<Vec<_>>());
        if repos.len() > 1 {
            payload["repoOptions"]=json!(repos.iter().map(|r|json!({"value":r,"label":Path::new(r).file_name().unwrap_or_default().to_string_lossy(),"selected":r==repo,"disabled":false,"message":r,"sessionSource":typed(source,r)})).collect::<Vec<_>>());
        }
        if source != "last-turn" {
            payload["pendingReplacement"] = json!(true);
            payload["statusMessage"] = json!(format!("Loading diff: {source}"));
        }
        payload["emptyMessage"] = json!(match source {
            "unstaged" => "No unstaged changes to diff.",
            "staged" => "No staged changes to diff.",
            "branch" => "No branch changes to diff.",
            _ => "No last-turn changes to diff.",
        });
        let session = json!({"token":token,"groupID":group,"repoRoot":repo,"allowedRepoRoots":repos,"layout":input.layout,"layoutSource":input.layout_source,"appearance":appearance,"titleOverride":input.title,"workspaceId":input.workspace,"surfaceId":input.surface,"repoSourceFiles":{}});
        atomic_write(
            &root.join(format!(".branch-session-{group}.json")),
            &serde_json::to_vec_pretty(&session)?,
        )?;
    }
    let config = json!({"payload":payload,"assets":assets.urls});
    let config = serde_json::to_string(&config)?
        .replace('<', "\\u003c")
        .replace('>', "\\u003e")
        .replace('&', "\\u0026")
        .replace('\u{2028}', "\\u2028")
        .replace('\u{2029}', "\\u2029");
    let pending = if input.source.is_some() && input.source != Some("last-turn") {
        " data-cmux-diff-pending=\"true\""
    } else {
        ""
    };
    let html=format!("<!doctype html>\n<html lang=\"{}\"{pending}><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"><title>{}</title><style id=\"cmux-diff-viewer-prepaint\">:root{{color-scheme:light dark;background:transparent}}html,body,#root{{min-height:100%}}html,body{{margin:0;background:transparent;color:#000}}@media(prefers-color-scheme:dark){{html,body{{color:#fff}}}}</style></head><body><script id=\"cmux-diff-viewer-config\" type=\"application/json\">{config}</script><div id=\"root\"></div><script type=\"module\" src=\"{}\"></script></body></html>",locale(),super::escape_html(input.title),assets.app);
    atomic_write(&path, html.as_bytes())?;
    files.insert(0, allowed(&root, &path, "text/html")?);
    atomic_write(
        &root.join(format!(".manifest-{token}.json")),
        &serde_json::to_vec_pretty(&json!({"token":token,"files":files}))?,
    )?;
    let url = format!(
        "cmux-diff-viewer://{token}/{}",
        path.file_name().unwrap().to_string_lossy()
    );
    Ok(Viewer {
        path,
        url,
        token,
        files,
    })
}

fn timestamp() -> String {
    std::process::Command::new("date")
        .args(["-u", "+%Y-%m-%dT%H:%M:%SZ"])
        .output()
        .ok()
        .filter(|v| v.status.success())
        .map(|v| String::from_utf8_lossy(&v.stdout).trim().to_owned())
        .unwrap_or_default()
}
pub fn atomic_write(path: &Path, bytes: &[u8]) -> Result<()> {
    let temp = path.with_file_name(format!(
        ".{}.{}.tmp",
        path.file_name().unwrap_or_default().to_string_lossy(),
        uuid::Uuid::new_v4()
    ));
    let mut file = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&temp)?;
    let result = (|| {
        file.write_all(bytes)?;
        file.sync_all()?;
        fs::rename(&temp, path)?;
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(temp);
    }
    result
}
fn allowed(root: &Path, path: &Path, mime: &str) -> Result<Value> {
    let canonical = fs::canonicalize(path)?;
    let relative = canonical.strip_prefix(root).map_err(|_| {
        CliError::new(
            "diff.path",
            "Diff viewer file is outside the viewer directory",
        )
    })?;
    let raw = relative.to_string_lossy();
    let raw = raw.strip_suffix(".deflate").unwrap_or(&raw);
    Ok(json!({"request_path":format!("/{raw}"),"file_path":canonical,"mime_type":mime}))
}
struct Assets {
    app: String,
    urls: Value,
    files: Vec<Value>,
}
fn asset_directories() -> Result<(PathBuf, PathBuf)> {
    let mut candidates = Vec::new();
    for executable in [
        env::var_os("CMUX_BUNDLED_CLI_PATH").map(PathBuf::from),
        env::current_exe().ok(),
    ]
    .into_iter()
    .flatten()
    {
        for ancestor in executable.ancestors().skip(1) {
            candidates.push(ancestor.join("markdown-viewer/diff-viewer"));
            candidates.push(ancestor.join("Resources/markdown-viewer/diff-viewer"));
            candidates.push(ancestor.join("Contents/Resources/markdown-viewer/diff-viewer"));
        }
    }
    // Repository resources are useful for the standalone development binary.
    candidates.push(
        PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../Resources/markdown-viewer/diff-viewer"),
    );
    for path in candidates {
        if !asset_exists(&path, "diffs.mjs") || !asset_exists(&path, "trees.mjs") {
            continue;
        }
        for app in ["webviews-app", "diff-viewer-app"] {
            let app_path = path.parent().unwrap().join(app);
            if asset_exists(&app_path, "main.mjs") {
                return Ok((path, app_path));
            }
        }
    }
    Err(CliError::new(
        "diff.assets_missing",
        "Bundled diff viewer assets not found",
    ))
}
fn asset_exists(dir: &Path, name: &str) -> bool {
    dir.join(name).is_file() || dir.join(format!("{name}.deflate")).is_file()
}
fn collect_assets(root: &Path) -> Result<Vec<(PathBuf, PathBuf)>> {
    fn visit(root: &Path, dir: &Path, out: &mut Vec<(PathBuf, PathBuf)>) -> Result<()> {
        for entry in fs::read_dir(dir)? {
            let entry = entry?;
            let name = entry.file_name();
            if name.to_string_lossy().starts_with('.') {
                continue;
            }
            let path = entry.path();
            let meta = fs::symlink_metadata(&path)?;
            if meta.file_type().is_symlink() {
                continue;
            }
            if meta.is_dir() {
                visit(root, &path, out)?;
            } else if meta.is_file() {
                let raw = path.to_string_lossy();
                let effective = raw.strip_suffix(".deflate").unwrap_or(&raw);
                if effective.ends_with(".mjs") || effective.ends_with(".js") {
                    out.push((path.strip_prefix(root).unwrap().to_path_buf(), path));
                }
            }
        }
        Ok(())
    }
    let mut out = Vec::new();
    visit(root, root, &mut out)?;
    out.sort_by(|a, b| a.0.cmp(&b.0));
    Ok(out)
}
fn copy_assets(root: &Path) -> Result<Assets> {
    let (source, app_source) = asset_directories()?;
    let pierre = collect_assets(&source)?;
    let app = collect_assets(&app_source)?;
    let mut hasher = Sha256::new();
    for (relative, path) in &app {
        hasher.update(relative.to_string_lossy().as_bytes());
        hasher.update(fs::read(path)?);
    }
    let hash = format!("{:x}", hasher.finalize());
    let app_name = format!("cmux-webviews-app-{}", &hash[..12]);
    let pierre_name = "pierre-diffs-1.2.7-trees-1.0.0-beta.4";
    let mut files = Vec::new();
    for (name, entries) in [(pierre_name, pierre), (app_name.as_str(), app)] {
        for (relative, source) in entries {
            let target = root.join("assets").join(name).join(relative);
            if let Some(parent) = target.parent() {
                fs::create_dir_all(parent)?;
            }
            let bytes = fs::read(source)?;
            if fs::read(&target).ok().as_deref() != Some(bytes.as_slice()) {
                atomic_write(&target, &bytes)?;
            }
            files.push(allowed(root, &target, "text/javascript")?);
        }
    }
    Ok(Assets {
        app: format!("./assets/{app_name}/main.mjs"),
        urls: json!({"diffsModuleURL":format!("./assets/{pierre_name}/diffs.mjs"),"treesModuleURL":format!("./assets/{pierre_name}/trees.mjs"),"workerPoolModuleURL":format!("./assets/{pierre_name}/worker-pool/worker-pool.mjs"),"workerModuleURL":format!("./assets/{pierre_name}/worker-pool/worker-portable.js")}),
        files,
    })
}

pub fn authorize_repo(repo: &str, token: Option<&str>, group: Option<&str>) -> Result<Value> {
    let root = directory()?;
    let canonical = fs::canonicalize(repo)?;
    if token.is_some_and(|v| !valid_token(v)) {
        return Err(CliError::new(
            "diff.not_allowed",
            "Invalid diff viewer capability token",
        ));
    }
    if group.is_some_and(|v| {
        v.len() > 64 || v.is_empty() || !v.chars().all(|c| c.is_ascii_alphanumeric() || c == '-')
    }) {
        return Err(CliError::new(
            "diff.not_allowed",
            "Invalid diff viewer group",
        ));
    }
    for entry in fs::read_dir(root)? {
        let entry = entry?;
        let name = entry.file_name().to_string_lossy().into_owned();
        if !name.starts_with(".branch-session-") || !name.ends_with(".json") {
            continue;
        }
        if let Some(group) = group {
            if name != format!(".branch-session-{group}.json") {
                continue;
            }
        }
        let bytes = fs::read(entry.path())?;
        if bytes.len() > 1024 * 1024 {
            continue;
        }
        let Ok(session) = serde_json::from_slice::<Value>(&bytes) else {
            continue;
        };
        if token.is_some_and(|v| session["token"].as_str() != Some(v)) {
            continue;
        }
        if session["allowedRepoRoots"]
            .as_array()
            .is_some_and(|values| {
                values
                    .iter()
                    .filter_map(Value::as_str)
                    .any(|value| fs::canonicalize(value).ok().as_ref() == Some(&canonical))
            })
        {
            return Ok(session);
        }
    }
    Err(CliError::new(
        "diff.not_allowed",
        "Repository is not in the diff viewer allow-list",
    ))
}
fn valid_token(v: &str) -> bool {
    (16..=80).contains(&v.len()) && v.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
}
fn repo_options(repo: &str) -> Vec<String> {
    let mut out = vec![repo.to_owned()];
    if let Ok(output) = std::process::Command::new("git")
        .args(["-C", repo, "worktree", "list", "--porcelain"])
        .output()
    {
        for line in String::from_utf8_lossy(&output.stdout).lines() {
            if let Some(path) = line.strip_prefix("worktree ") {
                if out.len() < 12 && !out.iter().any(|r| r == path) {
                    out.push(path.to_owned());
                }
            }
        }
    }
    out
}
fn locale() -> String {
    let raw = env::var("AppleLanguages")
        .or_else(|_| env::var("LANG"))
        .unwrap_or_else(|_| "en".into());
    raw.trim_matches(|c: char| c == '(' || c == '"' || c == '\'' || c.is_whitespace())
        .split([',', ')', '.'])
        .next()
        .unwrap_or("en")
        .replace('_', "-")
}
fn labels() -> Value {
    let catalog: Value =
        serde_json::from_str(include_str!("labels.json")).unwrap_or_else(|_| json!({}));
    let language = locale();
    let selected = catalog
        .get(&language)
        .or_else(|| catalog.get(language.split('-').next().unwrap_or("en")));
    let mut out = catalog["en"].clone();
    if let (Some(out), Some(selected)) = (out.as_object_mut(), selected.and_then(Value::as_object))
    {
        out.extend(selected.clone());
    }
    out
}

fn settings() -> Vec<Value> {
    let home = env::var("HOME").unwrap_or_default();
    [
        ".cmuxterm/settings.json",
        ".config/cmux/settings.json",
        ".config/cmux/cmux.json",
    ]
    .iter()
    .filter_map(|path| fs::read_to_string(Path::new(&home).join(path)).ok())
    .filter_map(|text| serde_json::from_str(&strip_json_comments(&text)).ok())
    .collect()
}
fn strip_json_comments(text: &str) -> String {
    let mut out = String::new();
    let mut chars = text.chars().peekable();
    let mut quoted = false;
    let mut escaped = false;
    while let Some(c) = chars.next() {
        if quoted {
            out.push(c);
            if escaped {
                escaped = false;
            } else if c == '\\' {
                escaped = true;
            } else if c == '"' {
                quoted = false;
            }
            continue;
        }
        if c == '"' {
            quoted = true;
            out.push(c);
        } else if c == '/' && chars.peek() == Some(&'/') {
            chars.next();
            for c in chars.by_ref() {
                if c == '\n' {
                    out.push(c);
                    break;
                }
            }
        } else if c == '/' && chars.peek() == Some(&'*') {
            chars.next();
            let mut prev = ' ';
            for c in chars.by_ref() {
                if prev == '*' && c == '/' {
                    break;
                }
                prev = c;
            }
        } else {
            out.push(c);
        }
    }
    out
}
pub fn default_layout() -> String {
    settings()
        .iter()
        .rev()
        .filter_map(|v| v["diffViewer"]["defaultLayout"].as_str())
        .find(|v| matches!(*v, "split" | "unified"))
        .unwrap_or("unified")
        .to_owned()
}
fn stroke(raw: &str) -> Option<Value> {
    let parts = raw.split('+').collect::<Vec<_>>();
    let key = parts.last()?.trim();
    let key = match key.to_ascii_lowercase().as_str() {
        "space" | "spacebar" | "<space>" => "space".to_owned(),
        "slash" => "/".into(),
        "period" | "dot" => ".".into(),
        "comma" => ",".into(),
        _ if key.chars().count() == 1 => key.to_lowercase(),
        _ => return None,
    };
    let mut out = json!({"key":key,"command":false,"shift":false,"option":false,"control":false});
    for modifier in parts.iter().take(parts.len() - 1) {
        let name = match modifier.trim().to_ascii_lowercase().as_str() {
            "cmd" | "command" | "⌘" => "command",
            "shift" | "⇧" => "shift",
            "opt" | "option" | "alt" | "⌥" => "option",
            "ctrl" | "control" | "ctl" | "⌃" => "control",
            _ => return None,
        };
        out[name] = json!(true);
    }
    Some(out)
}
fn binding(raw: &Value) -> Option<Value> {
    if raw.is_null() {
        return Some(json!({"unbound":true}));
    }
    let parts = if let Some(s) = raw.as_str() {
        vec![s]
    } else {
        raw.as_array()?
            .iter()
            .map(Value::as_str)
            .collect::<Option<Vec<_>>>()?
    };
    if parts.is_empty()
        || parts.len() == 1
            && matches!(
                parts[0].trim().to_ascii_lowercase().as_str(),
                "" | "none" | "clear" | "unbound" | "disabled"
            )
    {
        return Some(json!({"unbound":true}));
    }
    if parts.len() > 2 {
        return None;
    }
    let mut out = json!({"first":stroke(parts[0])?});
    if parts.len() == 2 {
        out["second"] = stroke(parts[1])?;
    }
    Some(out)
}
fn shortcuts() -> Value {
    let mut out = json!({});
    for (name, keys) in [
        ("ScrollDown", vec!["j"]),
        ("ScrollUp", vec!["k"]),
        ("ScrollHalfPageDown", vec!["ctrl+d"]),
        ("ScrollHalfPageUp", vec!["ctrl+u"]),
        ("ScrollDownEmacs", vec!["ctrl+n"]),
        ("ScrollUpEmacs", vec!["ctrl+p"]),
        ("ScrollToBottom", vec!["shift+g"]),
        ("ScrollToTop", vec!["g", "g"]),
        ("OpenFileSearch", vec!["/"]),
        ("NextFile", vec!["]", "f"]),
        ("PreviousFile", vec!["[", "f"]),
    ] {
        out[format!("diffViewer{name}")] = binding(&json!(keys)).unwrap();
    }
    for settings in settings() {
        if let Some(section) = settings["shortcuts"].as_object() {
            let mut bindings = section
                .get("bindings")
                .and_then(Value::as_object)
                .cloned()
                .unwrap_or_default();
            bindings.extend(
                section
                    .iter()
                    .filter(|(k, _)| k.as_str() != "bindings")
                    .map(|(k, v)| (k.clone(), v.clone())),
            );
            for (name, raw) in bindings {
                if out.get(&name).is_some() {
                    if let Some(value) = binding(&raw) {
                        out[&name] = value;
                    }
                }
            }
        }
    }
    out
}

fn appearance(ctx: &Context, size: Option<f64>) -> Value {
    let colors = [
        "#1a1a1a", "#cc372e", "#26a439", "#cdac08", "#0869cb", "#9647bf", "#479ec2", "#98989d",
        "#464646", "#ff453a", "#32d74b", "#ffd60a", "#0a84ff", "#bf5af2", "#76d6ff", "#ffffff",
    ];
    let palette = colors
        .iter()
        .enumerate()
        .map(|(i, v)| (i.to_string(), json!(v)))
        .collect::<serde_json::Map<_, _>>();
    let light = json!({"name":"cmux-ghostty-light","ghosttyName":"Apple System Colors Light","type":"light","background":"#feffff","foreground":"#000000","selectionBackground":"#abd8ff","selectionForeground":"#000000","palette":palette});
    let dark = json!({"name":"cmux-ghostty-dark","ghosttyName":"Apple System Colors","type":"dark","background":"#1e1e1e","foreground":"#ffffff","selectionBackground":"#3f638b","selectionForeground":"#ffffff","palette":palette});
    let mut out = json!({"backgroundOpacity":1.0,"fontFamily":"Menlo","fontSize":10.0,"lineHeight":20,"diffHeaderHeight":44,"theme":{"light":"cmux-ghostty-light","dark":"cmux-ghostty-dark"},"themes":{"light":light,"dark":dark}});
    let home = env::var("HOME").unwrap_or_default();
    let mut paths = vec![
        PathBuf::from(&home).join(".config/ghostty/config"),
        PathBuf::from(&home).join(".config/ghostty/config.ghostty"),
    ];
    let bundle = env::var("CMUX_BUNDLE_ID").unwrap_or_else(|_| {
        ctx.socket
            .as_deref()
            .and_then(|v| v.strip_prefix("/tmp/cmux-debug-"))
            .and_then(|v| v.strip_suffix(".sock"))
            .map(|tag| format!("com.cmuxterm.app.debug.{tag}"))
            .unwrap_or_else(|| "com.cmuxterm.app".into())
    });
    for b in ["com.mitchellh.ghostty", "com.cmuxterm.app", bundle.as_str()] {
        paths.push(PathBuf::from(&home).join(format!("Library/Application Support/{b}/config")));
        paths.push(
            PathBuf::from(&home).join(format!("Library/Application Support/{b}/config.ghostty")),
        );
    }
    for path in paths {
        if let Ok(text) = fs::read_to_string(path) {
            apply_config(&mut out, &text);
        }
    }
    if let Some(size) = size {
        out["fontSize"] = json!(size);
    }
    out
}
fn apply_config(out: &mut Value, text: &str) {
    for line in text.lines() {
        let line = line.trim();
        if line.starts_with('#') {
            continue;
        }
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        let value = value.trim();
        match key.trim() {
            "font-family" if !value.is_empty() => out["fontFamily"] = json!(value),
            "font-size" => {
                if let Ok(size) = value.parse::<f64>() {
                    if size.is_finite() && size > 0.0 && size <= 96.0 {
                        out["fontSize"] = json!(size);
                    }
                }
            }
            "background-opacity" => {
                if let Ok(v) = value.trim_end_matches('%').parse::<f64>() {
                    if v.is_finite() {
                        out["backgroundOpacity"] =
                            json!((v / if value.ends_with('%') { 100.0 } else { 1.0 })
                                .clamp(0.0, 1.0));
                    }
                }
            }
            "theme" => {
                for scheme in ["light", "dark"] {
                    if let Some(name) = theme_name(value, scheme) {
                        if let Some(text) = theme_text(&name) {
                            out["themes"][scheme]["ghosttyName"] = json!(name);
                            for line in text.lines() {
                                if let Some((key, value)) = line.split_once('=') {
                                    apply_color(
                                        &mut out["themes"][scheme],
                                        key.trim(),
                                        value.trim(),
                                    );
                                }
                            }
                        }
                    }
                }
            }
            key => {
                for scheme in ["light", "dark"] {
                    apply_color(&mut out["themes"][scheme], key, value);
                }
            }
        }
    }
}
fn theme_name(value: &str, scheme: &str) -> Option<String> {
    let mut fallback = None;
    for part in value.split(',') {
        if let Some((k, v)) = part.split_once(':') {
            if k.trim() == scheme {
                return Some(v.trim().into());
            }
        } else {
            fallback = Some(part.trim().into());
        }
    }
    fallback
}
fn theme_text(name: &str) -> Option<String> {
    let home = env::var("HOME").ok()?;
    let mut roots = Vec::new();
    if let Ok(p) = env::var("GHOSTTY_RESOURCES_DIR") {
        roots.push(PathBuf::from(p).join("themes"));
    }
    if let Ok(exe) = env::current_exe() {
        for a in exe.ancestors() {
            roots.push(a.join("ghostty/themes"));
            roots.push(a.join("Resources/ghostty/themes"));
        }
    }
    roots.extend([
        PathBuf::from("/Applications/Ghostty.app/Contents/Resources/ghostty/themes"),
        PathBuf::from(&home).join(".config/ghostty/themes"),
        PathBuf::from(&home).join("Library/Application Support/com.cmuxterm.app/themes"),
    ]);
    roots
        .iter()
        .find_map(|r| fs::read_to_string(r.join(name)).ok())
}
fn apply_color(theme: &mut Value, key: &str, raw: &str) {
    let value = raw.trim_start_matches('#');
    if key == "palette" {
        if let Some((index, color)) = raw.split_once('=') {
            if let Ok(index) = index.trim().parse::<u8>() {
                if let Some(color) = color_value(color.trim()) {
                    theme["palette"][index.to_string()] = json!(color);
                }
            }
        }
        return;
    }
    let field = match key {
        "background" => "background",
        "foreground" => "foreground",
        "selection-background" => "selectionBackground",
        "selection-foreground" => "selectionForeground",
        _ => return,
    };
    if let Some(color) = color_value(value) {
        theme[field] = json!(color);
    }
}
fn color_value(raw: &str) -> Option<String> {
    let raw = raw.trim_start_matches('#');
    if !raw.bytes().all(|b| b.is_ascii_hexdigit()) {
        return None;
    }
    match raw.len() {
        3 => Some(format!(
            "#{}",
            raw.chars().flat_map(|c| [c, c]).collect::<String>()
        )),
        6 => Some(format!("#{raw}")),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn bindings_preserve_sequences_and_unbound() {
        assert_eq!(binding(&json!(["g", "g"])).unwrap()["second"]["key"], "g");
        assert_eq!(binding(&Value::Null).unwrap()["unbound"], true);
        assert!(binding(&json!("meta+x")).is_none());
    }
    #[test]
    fn json_comments_preserve_url_strings() {
        let raw = "{\"url\":\"https://example.com\",/* note */\"n\":1}// tail";
        let value: Value = serde_json::from_str(&strip_json_comments(raw)).unwrap();
        assert_eq!(value["url"], "https://example.com");
    }
    #[test]
    fn generated_labels_cover_all_supported_locales() {
        let catalog: Value = serde_json::from_str(include_str!("labels.json")).unwrap();
        for locale in [
            "en", "de", "fr", "ar", "es", "zh-Hant", "zh-Hans", "ko", "ja",
        ] {
            assert!(catalog[locale].as_object().unwrap().len() > 70, "{locale}");
        }
    }
    #[test]
    fn asset_manifest_omits_compression_suffix() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("main.mjs.deflate");
        fs::write(&path, b"deflated").unwrap();
        let value = allowed(
            &fs::canonicalize(dir.path()).unwrap(),
            &path,
            "text/javascript",
        )
        .unwrap();
        assert_eq!(value["request_path"], "/main.mjs");
        assert!(value["file_path"].as_str().unwrap().ends_with(".deflate"));
    }
}
