use super::*;
use std::os::unix::fs::{PermissionsExt as _, symlink};

/// A program file at `at`.
fn program(at: &Path) {
    std::fs::create_dir_all(at.parent().unwrap()).unwrap();
    std::fs::write(at, "#!/bin/sh\n").unwrap();
    std::fs::set_permissions(at, std::fs::Permissions::from_mode(0o755)).unwrap();
}

/// A link at `link` to `target` (a relative target is read from the link's folder).
fn link(target: &Path, link: &Path) {
    std::fs::create_dir_all(link.parent().unwrap()).unwrap();
    symlink(target, link).unwrap();
}

/// An npm global install under `prefix`: `bin/<name>` links to `file` of package `package`
/// (`lib/node_modules/<package>`, with its `package.json`). The link, as npm makes it.
fn npm(prefix: &Path, name: &str, package: &str, file: &str) -> PathBuf {
    let root = prefix.join("lib/node_modules").join(package);
    std::fs::create_dir_all(&root).unwrap();
    std::fs::write(root.join("package.json"), format!("{{\"name\": \"{package}\"}}")).unwrap();
    program(&root.join(file));
    let bin = prefix.join("bin").join(name);
    link(&Path::new("../lib/node_modules").join(package).join(file), &bin);
    bin
}

fn argv(words: &[&str]) -> Vec<String> {
    words.iter().map(|w| (*w).to_owned()).collect()
}

fn family(words: &[&str], cwd: &Path, path: Option<&Path>) -> Option<String> {
    launch_family(&argv(words), cwd, path.map(Path::as_os_str))
}

/// The npm layouts of Claude Code, Codex, OpenCode and Gemini CLI: each `bin/<name>` links to a
/// file whose own name tells no family (`cli.js`, `index.js`) or tells the same one
/// (`codex.js`, `opencode`), in the agent's package. Found by path and by `PATH`.
#[test]
fn an_npm_install_keeps_its_family() {
    let d = tempfile::tempdir().unwrap();
    let cwd = d.path().join("work");
    std::fs::create_dir_all(&cwd).unwrap();
    let prefix = d.path().join("usr/local");
    let installs = [
        ("claude", "@anthropic-ai/claude-code", "cli.js"),
        ("codex", "@openai/codex", "bin/codex.js"),
        ("opencode", "opencode-ai", "bin/opencode"),
        ("gemini", "@google/gemini-cli", "dist/index.js"),
    ];
    let bin = prefix.join("bin");
    for (name, package, file) in installs {
        let at = npm(&prefix, name, package, file);
        let at = at.to_string_lossy().into_owned();
        assert_eq!(family(&[at.as_str(), "acp"], &cwd, None).as_deref(), Some(name), "{at}");
        assert_eq!(family(&[name], &cwd, Some(&bin)).as_deref(), Some(name), "{name} on PATH");
    }
}

/// Homebrew: a formula's `bin/<name>` links into its `Cellar` folder, to a native binary of the
/// agent's name (`codex`) or, for a Node agent, into the npm package under `libexec`
/// (`gemini-cli`).
#[test]
fn a_homebrew_install_keeps_its_family() {
    let d = tempfile::tempdir().unwrap();
    let cwd = d.path().join("work");
    std::fs::create_dir_all(&cwd).unwrap();
    let brew = d.path().join("opt/homebrew");
    program(&brew.join("Cellar/codex/0.50.0/bin/codex"));
    link(Path::new("../Cellar/codex/0.50.0/bin/codex"), &brew.join("bin/codex"));
    let libexec = brew.join("Cellar/gemini-cli/0.9.0/libexec");
    npm(&libexec, "gemini", "@google/gemini-cli", "dist/index.js");
    link(Path::new("../libexec/bin/gemini"), &brew.join("Cellar/gemini-cli/0.9.0/bin/gemini"));
    link(Path::new("../Cellar/gemini-cli/0.9.0/bin/gemini"), &brew.join("bin/gemini"));
    let bin = brew.join("bin");
    for name in ["codex", "gemini"] {
        assert_eq!(family(&[name], &cwd, Some(&bin)).as_deref(), Some(name), "{name}");
    }
}

/// A link named for one agent that runs another (by the file's name or its package), or a file
/// whose name and package disagree, has no family.
#[test]
fn a_program_that_runs_another_agent_has_none() {
    let d = tempfile::tempdir().unwrap();
    let cwd = d.path().join("work");
    std::fs::create_dir_all(&cwd).unwrap();
    program(&d.path().join("real/codex"));
    link(&d.path().join("real/codex"), &d.path().join("bin/opencode"));
    let codex = npm(&d.path().join("npm"), "codex", "@openai/codex", "bin/codex.js");
    link(&codex, &d.path().join("bin/gemini"));
    let mixed = npm(&d.path().join("mixed"), "codex", "opencode-ai", "bin/codex.js");
    let mixed = mixed.to_string_lossy().into_owned();
    let bin = d.path().join("bin");
    assert_eq!(family(&["opencode"], &cwd, Some(&bin)), None);
    assert_eq!(family(&["gemini"], &cwd, Some(&bin)), None);
    assert_eq!(family(&[mixed.as_str()], &cwd, None), None);
}

/// A program whose file tells no family keeps its written name's family outside the chat
/// folder (a person's own link or wrapper), never in it (the project's own file).
#[test]
fn an_unknown_file_counts_only_outside_the_chat_folder() {
    let d = tempfile::tempdir().unwrap();
    let cwd = d.path().join("work");
    program(&d.path().join("tools/runner"));
    link(&d.path().join("tools/runner"), &d.path().join("bin/opencode"));
    program(&cwd.join("tools/runner"));
    link(&cwd.join("tools/runner"), &cwd.join("opencode"));
    let outside = d.path().join("bin/opencode").to_string_lossy().into_owned();
    assert_eq!(family(&[outside.as_str()], &cwd, None).as_deref(), Some("opencode"));
    let inside = cwd.join("opencode").to_string_lossy().into_owned();
    assert_eq!(family(&[inside.as_str()], &cwd, None), None);
    assert_eq!(family(&["./opencode"], &cwd, None), None);
    // Found on a PATH folder in the chat folder.
    assert_eq!(family(&["opencode"], &cwd, Some(&cwd)), None);
}

/// A runner's package and a Python module have no file: their exact name decides. A written
/// name of no known program, and a program that cannot be found, have no family.
#[test]
fn names_without_a_file_and_unknown_names() {
    let d = tempfile::tempdir().unwrap();
    let cwd = d.path();
    let npx = ["npx", "-y", "@agentclientprotocol/codex-acp@1.10.0"];
    assert_eq!(family(&npx, cwd, None).as_deref(), Some("codex"));
    assert_eq!(family(&["npx", "-y", "my-codex-acp"], cwd, None), None);
    program(&cwd.join("bin/my-opencode-wrapper"));
    let wrapper = cwd.join("bin/my-opencode-wrapper").to_string_lossy().into_owned();
    assert_eq!(family(&[wrapper.as_str()], Path::new("/"), None), None);
    assert_eq!(family(&["/opt/missing/opencode"], cwd, None), None);
    assert_eq!(family(&["opencode"], cwd, None), None, "no PATH");
}
