//! `acpmux harness check|add`: validate and scaffold harness manifests
//! (`config/manifest.rs`). Both work on files only; no daemon is needed.

use std::path::{Path, PathBuf};

use anyhow::{Result, anyhow, bail};
use serde_json::{Value, json};

use crate::cli::output::print_json;
use crate::config::manifest::{self, MANIFEST_FILE, Problem};

/// The folders `check` looks at: one harness folder, a folder of them, or
/// an id in the user's harness folder; all of the user's when none is given.
fn targets(target: Option<&str>) -> Result<Vec<PathBuf>> {
    let user = manifest::user_dir().ok_or_else(|| anyhow!("no home folder"))?;
    let root = match target {
        None => user,
        Some(t) if Path::new(t).exists() => PathBuf::from(t),
        Some(t) if manifest::valid_id(t) => user.join(t),
        Some(t) => bail!("{t}: no such folder, and not a harness id"),
    };
    if root.join(MANIFEST_FILE).exists() {
        return Ok(vec![root]);
    }
    if !root.is_dir() {
        bail!(
            "{}: no {MANIFEST_FILE} here (create one with `acpmux harness add <id>`)",
            root.display()
        );
    }
    let mut dirs: Vec<PathBuf> = std::fs::read_dir(&root)?
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| p.is_dir() && p.join(MANIFEST_FILE).exists())
        .collect();
    dirs.sort();
    Ok(dirs)
}

pub fn check(target: Option<String>, json_out: bool) -> Result<()> {
    let dirs = targets(target.as_deref())?;
    let which = |bin: &str| crate::config::which_on_path(bin);
    let mut results = Vec::new();
    let mut bad = 0;
    for dir in &dirs {
        let name = dir.file_name().and_then(|n| n.to_str()).unwrap_or_default().to_string();
        match manifest::check_dir(dir) {
            Ok(loaded) => {
                let (profile, missing) = loaded.profile(&which);
                results
                    .push(json!({"id": name, "dir": dir, "ok": true, "name": loaded.manifest.name,
                    "argv": profile.argv, "warning": missing}));
            }
            Err(problems) => {
                bad += 1;
                results.push(json!({"id": name, "dir": dir, "ok": false, "problems": problems}));
            }
        }
    }
    if json_out {
        print_json(&json!({"harnesses": results}));
    } else if results.is_empty() {
        println!("no harness manifests (create one with `acpmux harness add <id>`)");
    } else {
        for r in &results {
            print_result(r);
        }
    }
    if bad > 0 {
        bail!("{bad} harness manifest{} with problems", if bad == 1 { "" } else { "s" });
    }
    Ok(())
}

fn print_result(r: &Value) {
    let id = r["id"].as_str().unwrap_or_default();
    if r["ok"].as_bool() == Some(true) {
        let argv: Vec<&str> =
            r["argv"].as_array().into_iter().flatten().filter_map(Value::as_str).collect();
        println!("ok   {id}: {} ({})", r["name"].as_str().unwrap_or(id), argv.join(" "));
        if let Some(w) = r["warning"].as_str() {
            println!("     warning: {w}");
        }
    } else {
        println!("FAIL {id} ({})", r["dir"].as_str().unwrap_or_default());
        let problems: Vec<Problem> =
            serde_json::from_value(r["problems"].clone()).unwrap_or_default();
        for p in problems {
            println!("     {p}");
        }
    }
}

/// The scaffold `add` writes: every field, with values to replace.
pub fn template(id: &str) -> Value {
    json!({
        "schema": manifest::SCHEMA,
        "id": id,
        "name": id,
        "description": format!("{id} coding agent"),
        "homepage": "https://example.com",
        "icon": "icon.svg",
        "run": {
            "protocol": "acp",
            "command": id,
            "args": ["acp"],
            "install": format!("see the {id} docs"),
        },
        "auth": {
            "logins": [{"id": "default", "label": "Sign in", "args": ["login"]}],
        },
        "models": {"source": "acp"},
        "capabilities": {"permissions": true},
    })
}

/// A placeholder mark, drawn in the theme's text color like the real ones.
pub const TEMPLATE_ICON: &str = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\"><rect x=\"3\" y=\"3\" width=\"18\" height=\"18\" rx=\"5\"/></svg>\n";

pub fn add(id: String, json_out: bool) -> Result<()> {
    if !manifest::valid_id(&id) {
        bail!("{id}: use 1-32 lowercase letters, digits and dashes, starting with a letter");
    }
    let root = manifest::user_dir().ok_or_else(|| anyhow!("no home folder"))?;
    let dir = root.join(&id);
    if dir.exists() {
        bail!("{} already exists; edit it, then run `acpmux harness check {id}`", dir.display());
    }
    std::fs::create_dir_all(&dir)?;
    let text = serde_json::to_string_pretty(&template(&id))? + "\n";
    crate::config::write_atomic(&dir.join(MANIFEST_FILE), text.as_bytes())?;
    crate::config::write_atomic(&dir.join("icon.svg"), TEMPLATE_ICON.as_bytes())?;
    if json_out {
        print_json(&json!({"id": id, "dir": dir}));
    } else {
        println!("created {}", dir.join(MANIFEST_FILE).display());
        println!(
            "next: set run.command and run.args to start your agent in ACP mode, list its sign-ins,"
        );
        println!(
            "      replace icon.svg, then `acpmux harness check {id}`. Running daemons pick it up on save."
        );
    }
    Ok(())
}

fn is_git_url(source: &str) -> bool {
    source.contains("://") || source.starts_with("git@") || source.ends_with(".git")
}

/// `add --from`: install the manifests a repository or folder ships. Only
/// harness.json and its icon are copied, after `check` passes; nothing from
/// the source runs here.
pub fn add_from(source: &str, id: Option<String>, replace: bool, json_out: bool) -> Result<()> {
    let root = manifest::user_dir().ok_or_else(|| anyhow!("no home folder"))?;
    let clone = is_git_url(source) && !Path::new(source).exists();
    let checkout = std::env::temp_dir().join(format!("acpmux-harness-{}", std::process::id()));
    let src = if clone {
        let _ = std::fs::remove_dir_all(&checkout);
        let status = std::process::Command::new("git")
            .args(["-c", "core.hooksPath=/dev/null", "clone", "--depth", "1", "--quiet", source])
            .arg(&checkout)
            .status()
            .map_err(|e| anyhow!("git: {e}"))?;
        if !status.success() {
            let _ = std::fs::remove_dir_all(&checkout);
            bail!("git clone {source} failed");
        }
        checkout.clone()
    } else {
        PathBuf::from(source)
    };
    let result = install_found(&src, &root, id.as_deref(), replace);
    if clone {
        let _ = std::fs::remove_dir_all(&checkout);
    }
    let installed = result?;
    if json_out {
        print_json(&json!({"installed": installed}));
    } else {
        for (id, dir) in &installed {
            println!("installed {id} in {}", dir.display());
        }
        println!("running daemons pick it up within a few seconds");
    }
    Ok(())
}

fn install_found(
    src: &Path,
    root: &Path,
    id: Option<&str>,
    replace: bool,
) -> Result<Vec<(String, PathBuf)>> {
    let mut found = manifest::find_in(src);
    if let Some(id) = id {
        found.retain(|d| d.file_name().and_then(|n| n.to_str()) == Some(id));
    }
    if found.is_empty() {
        bail!(
            "no harness{} in {} (looked for {MANIFEST_FILE} there and in .cmux/harnesses/, harnesses/)",
            id.map(|i| format!(" {i}")).unwrap_or_default(),
            src.display()
        );
    }
    let mut checked = Vec::new();
    for dir in &found {
        match manifest::check_dir(dir) {
            Ok(loaded) => checked.push(loaded),
            Err(problems) => {
                let lines: Vec<String> = problems.iter().map(|p| format!("  {p}")).collect();
                bail!("{} fails its check:\n{}", dir.display(), lines.join("\n"));
            }
        }
    }
    let mut installed = Vec::new();
    for loaded in checked {
        let dest = manifest::install(&loaded, root, replace)?;
        installed.push((loaded.manifest.id.clone(), dest));
    }
    Ok(installed)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scratch(name: &str) -> PathBuf {
        let dir =
            std::env::temp_dir().join(format!("acpmux-harness-cli-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn ship(repo: &Path, id: &str) {
        let dir = repo.join(".cmux").join("harnesses").join(id);
        std::fs::create_dir_all(&dir).unwrap();
        let mut m = template(id);
        m["run"]["command"] = json!("/bin/sh");
        std::fs::write(dir.join(MANIFEST_FILE), serde_json::to_string(&m).unwrap()).unwrap();
        std::fs::write(dir.join("icon.svg"), TEMPLATE_ICON).unwrap();
        std::fs::write(dir.join("setup.sh"), "echo never copied").unwrap();
    }

    #[test]
    fn harness_add_from_installs_only_manifest_and_icon() {
        let repo = scratch("repo");
        ship(&repo, "acme");
        ship(&repo, "acme-lite");
        let mine = scratch("mine");
        let installed = install_found(&repo, &mine, Some("acme"), false).unwrap();
        assert_eq!(installed.len(), 1);
        let mut files: Vec<String> = std::fs::read_dir(mine.join("acme"))
            .unwrap()
            .map(|e| e.unwrap().file_name().into_string().unwrap())
            .collect();
        files.sort();
        assert_eq!(files, ["harness.json", "icon.svg"]);
        // Same id again needs --replace; then it is replaced in place.
        assert!(install_found(&repo, &mine, Some("acme"), false).is_err());
        assert_eq!(install_found(&repo, &mine, None, true).unwrap().len(), 2);
        assert!(manifest::check_dir(&mine.join("acme-lite")).is_ok());
        // Nothing left over from staging, and the loader sees both.
        let (loaded, failed) = manifest::load_dir(&mine);
        assert_eq!(loaded.len(), 2);
        assert!(failed.is_empty());
    }

    #[test]
    fn harness_add_from_refuses_a_failing_manifest() {
        let repo = scratch("bad-repo");
        ship(&repo, "acme");
        let path = repo.join(".cmux/harnesses/acme").join(MANIFEST_FILE);
        let text =
            std::fs::read_to_string(&path).unwrap().replace("\"acp\"]", "\"acp\"], \"bogus\": 1");
        std::fs::write(&path, text).unwrap();
        let mine = scratch("bad-mine");
        let err = install_found(&repo, &mine, None, false).unwrap_err().to_string();
        assert!(err.contains("fails its check"), "{err}");
        assert!(!mine.join("acme").exists());
    }

    #[test]
    fn harness_project_offers_show_install_state() {
        let repo = scratch("offers");
        std::fs::create_dir_all(repo.join(".git")).unwrap();
        ship(&repo, "acme");
        let nested = repo.join("src").join("deep");
        std::fs::create_dir_all(&nested).unwrap();
        assert_eq!(manifest::project_dir(&nested), Some(repo.join(".cmux/harnesses")));
        let offers = manifest::offers(&nested);
        assert_eq!(offers.len(), 1);
        assert_eq!(offers[0].id, "acme");
        assert!(offers[0].icon.is_some());
    }
}
