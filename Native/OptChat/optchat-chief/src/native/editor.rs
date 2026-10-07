//! The text editor tool (Anthropic's `text_editor_20250728`,
//! `str_replace_based_edit_tool`): view, create, str_replace, insert.
//!
//! Paths are not confined to a root: the Chief works across the user's
//! files with the same reach as its `bash` tool, the approve-all policy the
//! acpmux engine runs with. A relative path is taken from the shell's
//! current directory.

use std::path::{Path, PathBuf};

use serde_json::Value;

/// Runs one editor command; Err is a result the model sees as an error.
pub fn run(input: &Value, cwd: &Path) -> Result<String, String> {
    let text = |k: &str| input.get(k).and_then(Value::as_str);
    let command = text("command").ok_or("missing `command`")?;
    let raw = text("path").ok_or("missing `path`")?;
    let path = resolve(raw, cwd);
    match command {
        "view" => view(&path, input.get("view_range")),
        "create" => {
            let body = text("file_text").ok_or("create needs `file_text`")?;
            if let Some(parent) = path.parent() {
                std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
            }
            std::fs::write(&path, body).map_err(|e| format!("{}: {e}", path.display()))?;
            Ok(format!("File created successfully at: {}", path.display()))
        }
        "str_replace" => {
            let old = text("old_str").ok_or("str_replace needs `old_str`")?;
            let new = text("new_str").unwrap_or("");
            let content = read(&path)?;
            match content.matches(old).count() {
                0 => Err(format!(
                    "No replacement was performed: old_str did not appear verbatim in {}.",
                    path.display()
                )),
                1 => {
                    std::fs::write(&path, content.replacen(old, new, 1))
                        .map_err(|e| format!("{}: {e}", path.display()))?;
                    Ok(format!("The file {} has been edited.", path.display()))
                }
                n => Err(format!(
                    "No replacement was performed: old_str appears {n} times in {}; make it unique.",
                    path.display()
                )),
            }
        }
        "insert" => {
            let line = input
                .get("insert_line")
                .and_then(Value::as_u64)
                .ok_or("insert needs `insert_line`")? as usize;
            let new = text("insert_text")
                .or_else(|| text("new_str"))
                .ok_or("insert needs `insert_text`")?;
            let content = read(&path)?;
            let mut lines: Vec<&str> = content.split_inclusive('\n').collect();
            if line > lines.len() {
                return Err(format!(
                    "insert_line {line} is past the end of {} ({} lines).",
                    path.display(),
                    lines.len()
                ));
            }
            let mut piece = new.to_owned();
            if !piece.ends_with('\n') {
                piece.push('\n');
            }
            // A last line without a newline gets one before the insert.
            let mut fixed_last = None;
            if line == lines.len()
                && let Some(last) = lines.last()
                && !last.ends_with('\n')
            {
                fixed_last = Some(format!("{last}\n"));
            }
            if let Some(last) = &fixed_last {
                let n = lines.len();
                lines[n - 1] = last;
            }
            lines.insert(line, &piece);
            std::fs::write(&path, lines.concat())
                .map_err(|e| format!("{}: {e}", path.display()))?;
            Ok(format!("The file {} has been edited.", path.display()))
        }
        other => Err(format!("unknown command {other}")),
    }
}

fn resolve(raw: &str, cwd: &Path) -> PathBuf {
    let path = Path::new(raw);
    if path.is_absolute() {
        path.to_owned()
    } else {
        cwd.join(path)
    }
}

fn read(path: &Path) -> Result<String, String> {
    std::fs::read_to_string(path).map_err(|e| format!("{}: {e}", path.display()))
}

/// A file with line numbers, or a directory two levels deep (hidden entries skipped).
fn view(path: &Path, range: Option<&Value>) -> Result<String, String> {
    if path.is_dir() {
        let mut out = Vec::new();
        list(path, path, 2, &mut out);
        out.sort();
        return Ok(format!("{}:\n{}", path.display(), out.join("\n")));
    }
    let content = read(path)?;
    let lines: Vec<&str> = content.lines().collect();
    let (start, end) = match range.and_then(Value::as_array).map(Vec::as_slice) {
        Some([a, b]) => {
            let start = a.as_i64().unwrap_or(1).max(1) as usize;
            let end = match b.as_i64() {
                Some(-1) | None => lines.len(),
                Some(n) => (n.max(0) as usize).min(lines.len()),
            };
            (start, end)
        }
        _ => (1, lines.len()),
    };
    if start > end && !(start == 1 && lines.is_empty()) {
        return Err(format!(
            "view_range [{start}, {end}] is outside {} ({} lines).",
            path.display(),
            lines.len()
        ));
    }
    Ok(lines
        .iter()
        .enumerate()
        .skip(start - 1)
        .take(end + 1 - start)
        .map(|(i, l)| format!("{:6}\t{l}", i + 1))
        .collect::<Vec<_>>()
        .join("\n"))
}

fn list(root: &Path, dir: &Path, depth: usize, out: &mut Vec<String>) {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let name = entry.file_name().to_string_lossy().into_owned();
        if name.starts_with('.') {
            continue;
        }
        let path = entry.path();
        let shown = path
            .strip_prefix(root)
            .unwrap_or(&path)
            .display()
            .to_string();
        if path.is_dir() {
            out.push(format!("{shown}/"));
            if depth > 1 {
                list(root, &path, depth - 1, out);
            }
        } else {
            out.push(shown);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn create_view_replace_insert() {
        let dir = tempfile::tempdir().unwrap();
        let cwd = dir.path();
        run(
            &json!({"command": "create", "path": "a/f.txt", "file_text": "one\ntwo\ntwo\n"}),
            cwd,
        )
        .unwrap();
        assert_eq!(
            run(
                &json!({"command": "view", "path": "a/f.txt", "view_range": [2, -1]}),
                cwd
            )
            .unwrap(),
            "     2\ttwo\n     3\ttwo"
        );
        let twice = run(
            &json!({"command": "str_replace", "path": "a/f.txt", "old_str": "two", "new_str": "2"}),
            cwd,
        );
        assert!(twice.unwrap_err().contains("2 times"));
        run(&json!({"command": "str_replace", "path": "a/f.txt", "old_str": "one\n", "new_str": "1\n"}), cwd).unwrap();
        run(&json!({"command": "insert", "path": "a/f.txt", "insert_line": 0, "insert_text": "zero"}), cwd).unwrap();
        assert_eq!(
            std::fs::read_to_string(cwd.join("a/f.txt")).unwrap(),
            "zero\n1\ntwo\ntwo\n"
        );
        let listing = run(
            &json!({"command": "view", "path": cwd.to_str().unwrap()}),
            cwd,
        )
        .unwrap();
        assert!(
            listing.contains("a/\n") && listing.contains("a/f.txt"),
            "{listing}"
        );
    }
}
