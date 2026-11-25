//! Which shell commands the dedupe callback may answer for (`dedupe.rs`), and what their output
//! depends on.
//!
//! Only a command whose output is a function of state acpmux can stat cheaply qualifies: one
//! simple command (no pipe, redirect, substitution, glob or variable), a program on a short
//! read-only list, and arguments whose every input is a regular file, a listed directory or a
//! repository's refs and index. Anything else passes through untouched. Not on the list on
//! purpose: `git status` and a work-tree `git diff` (a file edit changes them without touching
//! anything a stat of the repository sees), `gh pr view`/`gh pr checks` (they read GitHub, which
//! changes under them, and a repeat is usually a poll that wants the new answer), `find` and
//! recursive listings (a nested change moves no directory acpmux stats), and anything that reads
//! stdin, follows a file or prints a relative date.

use std::path::{Path, PathBuf};

/// The most directory entries one fingerprint stats; a bigger listing passes through.
const MAX_ENTRIES: usize = 4096;

/// What one command's output depends on: paths to stat (a directory's entries too) and the
/// repository whose refs and index it reads.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub(super) struct Inputs {
    pub files: Vec<PathBuf>,
    pub dirs: Vec<PathBuf>,
    pub repo: Option<PathBuf>,
}

/// The words of `command` when it is one simple command with plain quoting; `None` for any shell
/// syntax that could run or read more than its words say.
pub(super) fn words(command: &str) -> Option<Vec<String>> {
    const SYNTAX: &[char] = &[
        ';', '&', '|', '<', '>', '$', '`', '(', ')', '{', '}', '*', '?', '[', ']', '!', '~', '\\',
        '#', '\n', '\r',
    ];
    if command.contains(SYNTAX) || command.len() > 4096 {
        return None;
    }
    let mut out = Vec::new();
    let mut word = String::new();
    let mut in_word = false;
    let mut quote: Option<char> = None;
    for c in command.chars() {
        match (quote, c) {
            (Some(q), c) if c == q => quote = None,
            (Some(_), c) => word.push(c),
            (None, '\'' | '"') => {
                quote = Some(c);
                in_word = true;
            }
            (None, c) if c.is_whitespace() => {
                if in_word {
                    out.push(std::mem::take(&mut word));
                    in_word = false;
                }
            }
            (None, c) => {
                word.push(c);
                in_word = true;
            }
        }
    }
    if quote.is_some() {
        return None;
    }
    if in_word {
        out.push(word);
    }
    (!out.is_empty()).then_some(out)
}

/// The inputs of `command` run in `cwd`, when it is one acpmux can prove idempotent (module docs).
pub(super) fn inputs(command: &str, cwd: &Path) -> Option<Inputs> {
    let words = words(command)?;
    let (program, args) = words.split_first()?;
    let at = |p: &str| cwd.join(p);
    match program.as_str() {
        "cat" | "head" | "tail" | "wc" | "nl" | "md5sum" | "sha1sum" | "sha256sum" | "cmp"
        | "diff" => files_only(program, args, cwd),
        "grep" | "egrep" | "fgrep" | "rg" => search(program, args, cwd),
        "ls" => {
            let mut dirs = Vec::new();
            let mut files = Vec::new();
            for a in args {
                if a.starts_with('-') {
                    if a == "-R" || a == "--recursive" || (!a.starts_with("--") && a.contains('R'))
                    {
                        return None;
                    }
                    continue;
                }
                let p = at(a);
                let meta = std::fs::metadata(&p).ok()?;
                if meta.is_dir() { dirs.push(p) } else { files.push(p) }
            }
            if dirs.is_empty() && files.is_empty() {
                dirs.push(cwd.to_path_buf());
            }
            Some(Inputs { files, dirs, repo: None })
        }
        "git" => git(args, cwd),
        _ => None,
    }
}

/// A reader of the regular files it names (at least one; none reads stdin).
fn files_only(program: &str, args: &[String], cwd: &Path) -> Option<Inputs> {
    let takes_value: &[&str] = match program {
        "head" | "tail" => &["-n", "-c", "--lines", "--bytes"],
        _ => &[],
    };
    let mut files = Vec::new();
    let mut skip = false;
    for a in args {
        if std::mem::take(&mut skip) {
            continue;
        }
        if a.starts_with('-') && a != "-" {
            let short_follow = !a.starts_with("--") && (a.contains('f') || a.contains('F'));
            if program == "tail" && (short_follow || a.starts_with("--follow") || a == "--retry") {
                return None;
            }
            if program == "diff"
                && (a == "-r"
                    || a == "--recursive"
                    || a.starts_with("--from-file")
                    || a.starts_with("--to-file"))
            {
                return None;
            }
            skip = takes_value.contains(&a.as_str());
            continue;
        }
        files.push(regular(cwd, a)?);
    }
    if skip || files.is_empty() {
        return None;
    }
    Some(Inputs { files, ..Default::default() })
}

/// `grep`/`rg` over regular files it names: no pattern file, no preprocessor, no directory.
fn search(program: &str, args: &[String], cwd: &Path) -> Option<Inputs> {
    let rg = program == "rg";
    let banned = |a: &str| {
        a == "-f"
            || a.starts_with("--file")
            || a.starts_with("--pre")
            || a == "--files"
            || a.starts_with("--ignore-file")
            || (!rg
                && (a == "-r"
                    || a == "-R"
                    || a.starts_with("--recursive")
                    || a.starts_with("-d")
                    || a.starts_with("--directories")
                    || a.starts_with("--exclude-from")))
            || (rg && (a == "-z" || a == "--search-zip"))
    };
    let takes_value: &[&str] = if rg {
        &[
            "-e",
            "--regexp",
            "-A",
            "-B",
            "-C",
            "-m",
            "--max-count",
            "-g",
            "--glob",
            "-t",
            "--type",
            "-T",
            "--type-not",
            "-M",
            "--max-columns",
            "-j",
            "--threads",
            "-E",
            "--encoding",
            "--sort",
            "--sortr",
            "-r",
            "--replace",
            "--max-depth",
            "-d",
            "--context",
            "--after-context",
            "--before-context",
            "--color",
            "--colors",
            "--iglob",
            "--max-filesize",
            "-V",
        ]
    } else {
        &[
            "-e",
            "--regexp",
            "-A",
            "-B",
            "-C",
            "-m",
            "--max-count",
            "--label",
            "--context",
            "--after-context",
            "--before-context",
            "--color",
            "--colour",
            "--include",
            "--exclude",
            "--exclude-dir",
            "--group-separator",
        ]
    };
    let mut files = Vec::new();
    let mut pattern_given = false;
    let mut positional = Vec::new();
    let mut skip = false;
    let mut flags_done = false;
    for a in args {
        if std::mem::take(&mut skip) {
            continue;
        }
        if !flags_done && a == "--" {
            flags_done = true;
            continue;
        }
        if !flags_done && a.starts_with('-') && a != "-" {
            if banned(a) {
                return None;
            }
            if a == "-e"
                || a == "--regexp"
                || a.starts_with("--regexp=")
                || (a.starts_with("-e") && a.len() > 2)
            {
                pattern_given = true;
            }
            skip = takes_value.contains(&a.as_str());
            continue;
        }
        positional.push(a);
    }
    if skip {
        return None;
    }
    let paths = if pattern_given { &positional[..] } else { positional.get(1..)? };
    for p in paths {
        files.push(regular(cwd, p)?);
    }
    (!files.is_empty()).then_some(Inputs { files, ..Default::default() })
}

/// A git command that reads only the repository's refs, objects and index (module docs).
fn git(args: &[String], cwd: &Path) -> Option<Inputs> {
    let mut base = cwd.to_path_buf();
    let mut rest = args;
    loop {
        match rest.first().map(String::as_str) {
            Some("-C") => {
                base = base.join(rest.get(1)?);
                rest = rest.get(2..)?;
            }
            Some("--no-pager" | "--no-optional-locks" | "-P") => rest = rest.get(1..)?,
            _ => break,
        }
    }
    let (sub, sub_args) = rest.split_first()?;
    // Output that moves with the clock, or reads beyond the repository.
    let moves = |a: &str| {
        a.contains("relative")
            || a.contains("%ar")
            || a.contains("%cr")
            || a.contains("%gr")
            || a.contains("%ah")
            || a.contains("%ch")
            || a.starts_with("--since")
            || a.starts_with("--until")
            || a.starts_with("--after")
            || a.starts_with("--before")
            || a.starts_with("--output")
            || a == "--ext-diff"
            || a == "--no-index"
            || a.starts_with("--stdin")
            || a == "--follow"
            || a.contains("@{")
    };
    if sub_args.iter().any(|a| moves(a)) {
        return None;
    }
    let ok = match sub.as_str() {
        "log" | "show" | "rev-parse" | "rev-list" | "ls-tree" | "cat-file" | "merge-base"
        | "describe" | "for-each-ref" | "show-ref" => {
            !sub_args.iter().any(|a| a.starts_with("--batch"))
        }
        "diff" => {
            let cached = sub_args.iter().any(|a| a == "--cached" || a == "--staged");
            let range = sub_args
                .iter()
                .take_while(|a| *a != "--")
                .any(|a| !a.starts_with('-') && a.contains(".."));
            cached || range
        }
        "branch" => sub_args.iter().all(|a| {
            matches!(
                a.as_str(),
                "-a" | "--all"
                    | "-r"
                    | "--remotes"
                    | "-v"
                    | "-vv"
                    | "--verbose"
                    | "--list"
                    | "--show-current"
                    | "--no-color"
                    | "--color"
                    | "--no-column"
            )
        }),
        "tag" => {
            let listing = sub_args.iter().any(|a| a == "-l" || a == "--list");
            sub_args.iter().all(|a| {
                a.starts_with('-') && matches!(a.as_str(), "-l" | "--list" | "-n")
                    || listing && !a.starts_with('-')
            })
        }
        "ls-files" => sub_args.iter().all(|a| {
            !matches!(
                a.as_str(),
                "-o" | "--others"
                    | "-m"
                    | "--modified"
                    | "-d"
                    | "--deleted"
                    | "-k"
                    | "--killed"
                    | "-t"
                    | "-v"
                    | "-f"
                    | "--debug"
                    | "--eol"
            )
        }),
        _ => false,
    };
    if !ok {
        return None;
    }
    Some(Inputs { repo: Some(base), ..Default::default() })
}

/// `path` under `cwd` when it is a regular file.
fn regular(cwd: &Path, path: &str) -> Option<PathBuf> {
    let p = cwd.join(path);
    std::fs::metadata(&p).ok().filter(|m| m.is_file()).map(|_| p)
}

/// One path's identity and change stamps (a symlink's target's): (path, device, inode, size,
/// mtime ns, ctime ns), or a path that is not there.
#[cfg(unix)]
pub(super) fn stamp(path: &Path) -> String {
    use std::os::unix::fs::MetadataExt;
    match std::fs::metadata(path) {
        Ok(m) => format!(
            "{}:{}:{}:{}:{}.{}:{}.{}",
            path.display(),
            m.dev(),
            m.ino(),
            m.len(),
            m.mtime(),
            m.mtime_nsec(),
            m.ctime(),
            m.ctime_nsec()
        ),
        Err(_) => format!("{}:-", path.display()),
    }
}

/// One path's size and modification time, or a path that is not there.
#[cfg(not(unix))]
pub(super) fn stamp(path: &Path) -> String {
    match std::fs::metadata(path) {
        Ok(m) => format!("{}:{}:{:?}", path.display(), m.len(), m.modified().ok()),
        Err(_) => format!("{}:-", path.display()),
    }
}

/// A fingerprint of everything `inputs` names: equal fingerprints mean the command's output is
/// the same. `None` when it cannot be taken (a directory too big, a repository not found).
pub(super) fn fingerprint(inputs: &Inputs) -> Option<String> {
    let mut parts = Vec::new();
    for f in &inputs.files {
        parts.push(stamp(f));
    }
    let mut budget = MAX_ENTRIES;
    for d in &inputs.dirs {
        parts.push(stamp(d));
        let mut names: Vec<_> =
            std::fs::read_dir(d).ok()?.filter_map(|e| e.ok()).map(|e| e.path()).collect();
        if names.len() > budget {
            return None;
        }
        budget -= names.len();
        names.sort();
        parts.extend(names.iter().map(|p| stamp(p)));
    }
    if let Some(base) = &inputs.repo {
        parts.push(repo_stamp(base, &mut budget)?);
    }
    Some(parts.join("\n"))
}

/// The repository at or above `base`: its HEAD, index, config, packed refs and every loose ref
/// (a ref update renames a file into place, which changes it and its directory).
fn repo_stamp(base: &Path, budget: &mut usize) -> Option<String> {
    let mut dir = base.canonicalize().ok()?;
    let (top, git_dir) = loop {
        let dot = dir.join(".git");
        if let Ok(m) = std::fs::metadata(&dot) {
            if m.is_dir() {
                break (dir.clone(), dot);
            }
            let text = std::fs::read_to_string(&dot).ok()?;
            let target = text.strip_prefix("gitdir:")?.trim();
            break (dir.clone(), dir.join(target));
        }
        if !dir.pop() {
            return None;
        }
    };
    let common = match std::fs::read_to_string(git_dir.join("commondir")) {
        Ok(text) => git_dir.join(text.trim()),
        Err(_) => git_dir.clone(),
    };
    let mut parts = Vec::new();
    for name in ["HEAD", "index", "config.worktree", "ORIG_HEAD", "MERGE_HEAD", "CHERRY_PICK_HEAD"]
    {
        parts.push(stamp(&git_dir.join(name)));
    }
    for name in ["packed-refs", "config", "FETCH_HEAD", "shallow", "info/grafts"] {
        parts.push(stamp(&common.join(name)));
    }
    parts.push(stamp(&top.join(".mailmap")));
    let mut roots = vec![common.join("refs")];
    if git_dir != common {
        roots.push(git_dir.join("refs"));
    }
    while let Some(d) = roots.pop() {
        parts.push(stamp(&d));
        let Ok(entries) = std::fs::read_dir(&d) else { continue };
        for e in entries.filter_map(|e| e.ok()) {
            *budget = budget.checked_sub(1)?;
            let p = e.path();
            if e.file_type().ok()?.is_dir() {
                roots.push(p);
            } else {
                parts.push(stamp(&p));
            }
        }
    }
    parts.sort();
    Some(parts.join("\n"))
}
