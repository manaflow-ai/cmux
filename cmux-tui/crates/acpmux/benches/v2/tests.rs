use super::*;

/// Rows intentionally left without a source writer while a later PR owns their gate.
const WAITS_ON_ANOTHER_PR: &[&str] = &["v2.pr12.follow_driver_views"];

/// A gate name as a source spells it. A `{..}` hole is a name built by `format!`. A PR's
/// part is its number and then any letters and digits (`03a3`).
const NAME_IN_SOURCE: &str = r"v2\.pr[0-9]+[a-z0-9]*\.(?:[a-z0-9_]|\{[^{}]*\})+";

fn rust_sources(dir: &Path, found: &mut Vec<PathBuf>) {
    let entries = fs::read_dir(dir).unwrap_or_else(|e| panic!("{dir:?}: {e}"));
    for entry in entries {
        let path = entry.unwrap_or_else(|e| panic!("{dir:?}: {e}")).path();
        if path.is_dir() {
            rust_sources(&path, found);
        } else if path.extension().is_some_and(|extension| extension == "rs") {
            found.push(path);
        }
    }
}

/// Every gate name the acpmux crates' sources hold (and `cmux-tui-core`'s, whose list
/// callers' gates are row 7c's), with the file that holds it. This file and the row files
/// are left out: their rows are what the names are checked against. `v2.pr99` is the made-up
/// PR the report's own tests use.
fn names_in_sources() -> Vec<(String, PathBuf)> {
    let registry = Path::new(env!("CARGO_MANIFEST_DIR")).join("benches/v2");
    let files = gate_writer_sources();
    let pattern = regex::Regex::new(NAME_IN_SOURCE).unwrap();
    let mut names = Vec::new();
    for file in files {
        if file.starts_with(&registry) {
            continue;
        }
        let text = fs::read_to_string(&file).unwrap_or_else(|e| panic!("{file:?}: {e}"));
        for found in pattern.find_iter(&text) {
            if !found.as_str().starts_with("v2.pr99.") {
                names.push((found.as_str().to_owned(), file.clone()));
            }
        }
    }
    names
}

/// The Rust sources of the acpmux crates and `cmux-tui-core`: every file a gate line can be
/// written from.
fn gate_writer_sources() -> Vec<PathBuf> {
    let crates = Path::new(env!("CARGO_MANIFEST_DIR")).parent().unwrap().to_path_buf();
    let mut files = Vec::new();
    for entry in fs::read_dir(&crates).unwrap() {
        let path = entry.unwrap().path();
        let is_ours = path
            .file_name()
            .and_then(|name| name.to_str())
            .is_some_and(|name| name.starts_with("acpmux") || name == "cmux-tui-core");
        for part in ["src", "tests", "benches"] {
            if is_ours && path.join(part).is_dir() {
                rust_sources(&path.join(part), &mut files);
            }
        }
    }
    files
}

/// The string literal around `at`: from the quote before it that no backslash escapes to the
/// next such quote. A `\`-continued literal spans its lines.
fn literal_around(text: &str, at: usize) -> &str {
    let bytes = text.as_bytes();
    let is_quote = |index: usize| bytes[index] == b'"' && (index == 0 || bytes[index - 1] != b'\\');
    let start = (0..at).rev().find(|index| is_quote(*index)).map_or(0, |index| index + 1);
    let end = (at..bytes.len()).find(|index| is_quote(*index)).unwrap_or(bytes.len());
    &text[start..end]
}

/// The gate lines a source writes by hand: each format string holding `\"name\":\"v2.`, with
/// the file and line it starts on, that lacks `small_p95` or `god_p95`.
fn hand_written_lines_without_the_home_shape(file: &Path, text: &str) -> Vec<String> {
    let mut found = Vec::new();
    for (at, _) in text.match_indices(r#"\"name\":\"v2."#) {
        let literal = literal_around(text, at);
        let lacks: Vec<_> = [r#"\"small_p95\":"#, r#"\"god_p95\":"#]
            .into_iter()
            .filter(|field| !literal.contains(field))
            .collect();
        if !lacks.is_empty() {
            let line = text[..at].lines().count();
            found.push(format!("{file:?}:{line} lacks {lacks:?}: {literal}"));
        }
    }
    found
}

/// Where a `"name": "v2.` key stands among the `json!` calls around it.
#[derive(Debug, PartialEq)]
enum JsonPlace<'a> {
    /// In the object a `json!(` call opens: that object, from its `{` to its `}`.
    Object(&'a str),
    /// In an object or array nested inside a `json!` value: the scan cannot place it.
    Nested,
    /// No `json!` call holds it.
    Outside,
}

/// Where the key at `at` stands: the brackets before it that nothing closes are walked from
/// the innermost out, and the first that opens a `json!(` call decides. Brackets are counted
/// as they stand, so a string value holding one would mislead it; no gate line has one.
fn json_place(text: &str, at: usize) -> JsonPlace<'_> {
    let bytes = text.as_bytes();
    let opens_json = |open: usize| text[..open].trim_end().ends_with("json!(");
    let (mut depth, mut innermost) = (0_usize, true);
    for index in (0..at).rev() {
        match bytes[index] {
            b'}' | b']' => depth += 1,
            b'{' | b'[' if depth > 0 => depth -= 1,
            b'{' | b'[' => {
                if opens_json(index) {
                    let close = if innermost && bytes[index] == b'{' {
                        closing_brace(text, index)
                    } else {
                        None
                    };
                    return close.map_or(JsonPlace::Nested, |close| {
                        JsonPlace::Object(&text[index..=close])
                    });
                }
                innermost = false;
            }
            _ => {}
        }
    }
    JsonPlace::Outside
}

/// The `}` that closes the `{` at `open`.
fn closing_brace(text: &str, open: usize) -> Option<usize> {
    let bytes = text.as_bytes();
    let mut depth = 0_usize;
    (open..bytes.len()).find(|index| match bytes[*index] {
        b'{' => {
            depth += 1;
            false
        }
        b'}' => {
            depth -= 1;
            depth == 0
        }
        _ => false,
    })
}

/// The gate lines a source spells as a `json!` object with a `"name": "v2.` key: how many it
/// read, those of them that lack `small_p95` or `god_p95`, and those nested inside another
/// `json!` value, which it cannot place; each with the file and line its name is on.
fn json_lines_without_the_home_shape(file: &Path, text: &str) -> (usize, Vec<String>, Vec<String>) {
    let name = regex::Regex::new(r#""name"\s*:\s*"v2\."#).unwrap();
    let (mut lines, mut found, mut unplaced) = (0, Vec::new(), Vec::new());
    for at in name.find_iter(text).map(|m| m.start()) {
        let line = text[..at].lines().count();
        let object = match json_place(text, at) {
            JsonPlace::Object(object) => object,
            JsonPlace::Nested => {
                unplaced.push(format!("{file:?}:{line}"));
                continue;
            }
            JsonPlace::Outside => continue,
        };
        lines += 1;
        let lacks: Vec<_> = ["small_p95", "god_p95"]
            .into_iter()
            .filter(|field| {
                !regex::Regex::new(&format!(r#""{field}"\s*:"#)).unwrap().is_match(object)
            })
            .collect();
        if !lacks.is_empty() {
            found.push(format!("{file:?}:{line} lacks {lacks:?}: {object}"));
        }
    }
    (lines, found, unplaced)
}

/// The home reads `small_p95` and `god_p95` from every line (`parse_measure`); a hand-written
/// line without them once stopped the nightly report from being written at all. A line is
/// hand-written as a format string holding `\"name\":\"v2.` or as a `json!` object with a
/// `"name": "v2.` key; both are read.
#[test]
fn a_hand_written_gate_line_carries_small_p95_and_god_p95() {
    // The registry's own tests spell broken lines on purpose.
    let registry = Path::new(env!("CARGO_MANIFEST_DIR")).join("benches/v2");
    let (mut lines, mut json_lines) = (0, 0);
    let (mut found, mut unplaced) = (Vec::new(), Vec::new());
    for file in gate_writer_sources() {
        if file.starts_with(&registry) {
            continue;
        }
        let text = fs::read_to_string(&file).unwrap_or_else(|e| panic!("{file:?}: {e}"));
        lines += text.matches(r#"\"name\":\"v2."#).count();
        found.extend(hand_written_lines_without_the_home_shape(&file, &text));
        let (in_json, lacking, nested) = json_lines_without_the_home_shape(&file, &text);
        json_lines += in_json;
        found.extend(lacking);
        unplaced.extend(nested);
    }
    assert!(lines >= 3, "the scan read too few hand-written gate lines: {lines}");
    assert!(json_lines >= 3, "the scan read too few json! gate lines: {json_lines}");
    assert!(found.is_empty(), "gate lines the home cannot read:\n{}", found.join("\n"));
    let unplaced = unplaced.join("\n");
    assert!(unplaced.is_empty(), "gate lines inside another json! value, unread:\n{unplaced}");
}

#[test]
fn the_hand_written_line_check_reads_the_whole_format_string() {
    let without = concat!(
        r#"format!("{{\"name\":\"v2.pr08.mirror_local_row_thirty\",\"capped_p95\":{c},"#,
        r#"\"unit\":\"ns\"}}")"#
    );
    let found = hand_written_lines_without_the_home_shape(Path::new("a.rs"), without);
    assert_eq!(found.len(), 1, "{found:?}");
    assert!(found[0].contains("small_p95") && found[0].contains("god_p95"), "{found:?}");
    let continued = concat!(
        r#"format!("{{\"name\":\"v2.pr08.mirror_local_row_thirty\",\"small_p95\":0,\"#,
        "\n",
        r#"    \"god_p95\":{c},\"unit\":\"ns\"}}")"#
    );
    assert!(hand_written_lines_without_the_home_shape(Path::new("a.rs"), continued).is_empty());
}

#[test]
fn the_json_line_check_reads_the_whole_object() {
    let without = concat!(
        "write_gate_line(&json!({\n",
        r#"    "name": "v2.pr06.client_chat_held", "capped": {"p95": 1}, "unit": "bytes""#,
        "\n}));"
    );
    let (lines, found, unplaced) = json_lines_without_the_home_shape(Path::new("a.rs"), without);
    assert_eq!((lines, found.len(), unplaced.len()), (1, 1, 0), "{found:?}");
    assert!(found[0].contains("small_p95") && found[0].contains("god_p95"), "{found:?}");
    let with = concat!(
        "let line = serde_json::json!({\n",
        r#"    "name":"v2.pr04b.mirror_v1_rows", "rounds": {"n": 5},"#,
        "\n",
        r#"    "small_p95":small, "god_p95":god, "unit":"ns""#,
        "\n});"
    );
    let none = Vec::<String>::new;
    assert_eq!(json_lines_without_the_home_shape(Path::new("a.rs"), with), (1, none(), none()));
    let not_json = r#"let row = Row { name: "v2.x" }; let v = map(&{ "name": "v2.y" });"#;
    let read = json_lines_without_the_home_shape(Path::new("a.rs"), not_json);
    assert_eq!(read, (0, none(), none()));
}

/// A gate line nested inside another `json!` value is no object the scan can check: it is
/// counted and named, never skipped without a sound.
#[test]
fn the_json_line_check_names_a_line_it_cannot_place() {
    let in_array = concat!(
        "write_gate_line(&json!({\n",
        r#"    "rows": [{"name": "v2.pr06.client_chat_held", "capped": {"p95": 1}}]"#,
        "\n}));"
    );
    let (lines, found, unplaced) = json_lines_without_the_home_shape(Path::new("a.rs"), in_array);
    assert_eq!((lines, found.len()), (0, 0), "{found:?}");
    assert_eq!(unplaced, vec![r#""a.rs":2"#.to_string()]);
    let in_object = concat!(
        "let line = json!({\n",
        r#"    "meta": {"name": "v2.pr06.client_chat_held"}, "small_p95": 1, "god_p95": 2"#,
        "\n});"
    );
    let (lines, _, unplaced) = json_lines_without_the_home_shape(Path::new("a.rs"), in_object);
    assert_eq!((lines, unplaced.len()), (0, 1), "{unplaced:?}");
}

/// Whether a source's name is this row's: equal, or a `format!` whose holes fit.
fn spells(in_source: &str, row: &str) -> bool {
    if !in_source.contains('{') {
        return in_source == row;
    }
    let hole = regex::Regex::new(r"\\\{[^{}]*\\\}").unwrap();
    let escaped = regex::escape(in_source);
    regex::Regex::new(&format!("^{}$", hole.replace_all(&escaped, "[a-z0-9_]+")))
        .unwrap()
        .is_match(row)
}

/// The scan finds a row's name in a source only when the pattern matches it whole. A row it
/// cannot spell reads as a row no source writes and no script line reaches, however the
/// source and the script are written, so the row fails here, in the PR that adds it.
#[test]
fn every_registry_name_is_one_the_source_scan_can_spell() {
    let pattern = regex::Regex::new(&format!("^(?:{NAME_IN_SOURCE})$")).unwrap();
    for row in GATE_ROWS {
        assert!(
            pattern.is_match(row.name),
            "the source scan's pattern cannot spell the registry name {}",
            row.name
        );
    }
}

#[test]
fn every_gate_name_in_a_source_has_a_registry_row() {
    let names = names_in_sources();
    assert!(names.len() >= 20, "the scan read too few gate names: {names:?}");
    for (name, file) in &names {
        assert!(
            GATE_ROWS.iter().any(|row| spells(name, row.name)),
            "{file:?} names the gate {name}, and the registry has no row for it"
        );
    }
}

#[test]
fn a_pr_that_writes_a_row_has_no_placeholder_left() {
    let names = names_in_sources();
    let written = |row: &GateRow| names.iter().any(|(name, _)| spells(name, row.name));
    for row in GATE_ROWS {
        if written(row) {
            continue;
        }
        assert!(!row.measured, "{} is marked measured and no source writes it", row.name);
        let pr_writes = GATE_ROWS.iter().any(|other| other.pr == row.pr && written(other));
        assert!(
            !pr_writes || WAITS_ON_ANOTHER_PR.contains(&row.name),
            "PR {} writes its rows and no source writes {}: remove the placeholder",
            row.pr,
            row.name
        );
    }
}

#[test]
fn a_format_built_name_fits_only_its_own_rows() {
    assert!(spells("v2.pr05b.page_{label}_bytes", "v2.pr05b.page_first_bytes"));
    assert!(!spells("v2.pr05b.page_{label}_bytes", "v2.pr05b.page_first"));
    assert!(!spells("v2.pr05b.page_{label}", "v2.pr05b.hot_rss"));
    assert!(spells("v2.pr01.append_time", "v2.pr01.append_time"));
    assert!(!spells("v2.pr01.append", "v2.pr01.append_time"));
}

/// The repository's root, where the nightly's gate script and its lines are.
fn repository() -> PathBuf {
    // affected-reads: scripts/cmux-next cmux-tui
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../..")
}

/// A crate and one of its test targets: `lib`, or a test binary's name.
type Target = (String, String);

/// A function of a source: its name, its first line and its last.
type Function = (String, usize, usize);

/// The script's gate lines, each as the target it runs and its filter. A runner is a shell
/// function whose `cargo test` names a crate and `--lib` or one `--test`; a line of a
/// runner's name and one word runs that target's tests whose names hold the word.
fn gate_script_filters(script: &str) -> Vec<(Target, String)> {
    let opened = regex::Regex::new(r"^(run_[a-z_]+)\(\) \{$").unwrap();
    let cargo = regex::Regex::new(r#"cargo test .*-p (\S+) (?:--lib|--test (\S+)) "\$1""#).unwrap();
    let mut runners: HashMap<&str, Target> = HashMap::new();
    let mut current = None;
    let mut filters = Vec::new();
    for line in script.lines() {
        let words: Vec<&str> = line.split_whitespace().collect();
        if let Some(found) = opened.captures(line) {
            current = found.get(1).map(|runner| runner.as_str());
        } else if line == "}" {
            current = None;
        } else if let (Some(runner), Some(found)) = (current, cargo.captures(line)) {
            let target = found.get(2).map_or("lib", |target| target.as_str());
            runners.insert(runner, (found[1].to_owned(), target.to_owned()));
        } else if let [runner, filter] = words[..]
            && let Some(target) = runners.get(runner)
        {
            filters.push((target.clone(), filter.to_owned()));
        }
    }
    filters
}

/// The target a source is compiled into: `lib` under `src`, the binary's name under `tests`.
/// A bench has none: the gate script runs tests only.
fn target_of(file: &Path) -> Option<Target> {
    let crates = Path::new(env!("CARGO_MANIFEST_DIR")).parent()?;
    let mut parts = file.strip_prefix(crates).ok()?.iter().filter_map(|part| part.to_str());
    let package = parts.next()?.to_owned();
    let target = match parts.next()? {
        "src" => "lib",
        "tests" => {
            let binary = parts.next()?;
            binary.strip_suffix(".rs").unwrap_or(binary)
        }
        _ => return None,
    };
    Some((package, target.to_owned()))
}

/// A source's lines, its functions, and each gate name it spells with the name's line.
struct Source<'a> {
    lines: Vec<&'a str>,
    functions: Vec<Function>,
    names: Vec<(usize, &'a str)>,
}

impl<'a> Source<'a> {
    /// Functions are read by rustfmt's indentation: one ends at the first later line that is
    /// its own indentation and a `}`, and one whose first line ends it (`fn f() {}`, a
    /// trait's `fn f();`) is that line alone.
    fn read(text: &'a str) -> Self {
        let lines: Vec<&'a str> = text.lines().collect();
        let opened =
            regex::Regex::new(r"^( *)(?:pub(?:\([a-z:]+\))? )?(?:async )?fn ([a-z0-9_]+)").unwrap();
        let name = regex::Regex::new(NAME_IN_SOURCE).unwrap();
        let mut functions = Vec::new();
        let mut names = Vec::new();
        for (at, line) in lines.iter().copied().enumerate() {
            names.extend(name.find_iter(line).map(|found| (at, found.as_str())));
            let Some(found) = opened.captures(line) else { continue };
            let close = format!("{}}}", &found[1]);
            let last = if line.ends_with('}') || line.ends_with(';') {
                at
            } else {
                let later = lines[at + 1..].iter().position(|later| *later == close);
                later.map_or(at, |later| at + 1 + later)
            };
            functions.push((found[2].to_owned(), at, last));
        }
        Self { lines, functions, names }
    }

    /// The functions that reach a line spelling this row's name: the functions around the
    /// line, then every function of this source that calls one already reached, so a test
    /// that writes its rows through a helper is found. A helper that many tests call makes
    /// the check weak for its rows (a gate line for any of those tests passes them); it
    /// never fails a row whose test the script runs.
    fn reaches(&self, row: &str) -> HashSet<String> {
        let mut reached: HashSet<String> = HashSet::new();
        for (at, name) in &self.names {
            if spells(name, row) {
                let around =
                    self.functions.iter().filter(|(_, first, last)| first <= at && at <= last);
                reached.extend(around.map(|(function, _, _)| function.clone()));
            }
        }
        loop {
            let calls: Vec<regex::Regex> = reached
                .iter()
                .map(|function| regex::Regex::new(&format!(r"\b{function}\(")).unwrap())
                .collect();
            let calls_one = |line: &&str| calls.iter().any(|call| call.is_match(line));
            let callers: Vec<String> = self
                .functions
                .iter()
                .filter(|(function, first, last)| {
                    !reached.contains(function)
                        && self.lines[first + 1..=*last].iter().any(calls_one)
                })
                .map(|(function, _, _)| function.clone())
                .collect();
            if callers.is_empty() {
                return reached;
            }
            reached.extend(callers);
        }
    }

    /// `from` and every function of this source that one of them calls, and so on: the
    /// functions a row's line can be written through.
    fn called_from(&self, from: HashSet<String>) -> HashSet<String> {
        let mut called = from;
        loop {
            let bodies: Vec<&str> = self
                .functions
                .iter()
                .filter(|(function, _, _)| called.contains(function))
                .flat_map(|(_, first, last)| self.lines[*first + 1..=*last].iter().copied())
                .collect();
            let more: Vec<String> = self
                .functions
                .iter()
                .map(|(function, _, _)| function)
                .filter(|function| {
                    let call = regex::Regex::new(&format!(r"\b{function}\(")).unwrap();
                    !called.contains(*function) && bodies.iter().any(|line| call.is_match(line))
                })
                .cloned()
                .collect();
            if more.is_empty() {
                return called;
            }
            called.extend(more);
        }
    }

    /// Whether one of `functions` calls [`acpmux_book::gate_rounds::report`].
    fn reports_rounds(&self, functions: &HashSet<String>) -> bool {
        self.functions.iter().filter(|(function, _, _)| functions.contains(function)).any(
            |(_, first, last)| {
                self.lines[*first..=*last].iter().any(|line| line.contains("gate_rounds::report("))
            },
        )
    }

    /// Whether one of `functions` calls the function `callee`.
    fn calls(&self, functions: &HashSet<String>, callee: &str) -> bool {
        let call = regex::Regex::new(&format!(r"\b{callee}\(")).unwrap();
        self.functions
            .iter()
            .filter(|(function, _, _)| functions.contains(function))
            .any(|(_, first, last)| self.lines[*first + 1..=*last].iter().any(|l| call.is_match(l)))
    }
}

/// Helpers that write `god_p95_all` for the rows their callers name, by the file (under this
/// crate) that defines each: a caller writes that line without spelling `god_p95_all`. A
/// helper here reports the rounds it is given, so a row written through it reports them.
const SHARED_WRITERS: &[(&str, &str)] = &[("src/test_support/list_daemon.rs", "emit_with_all")];

/// Whether one of `functions` in `source` writes its line through a [`SHARED_WRITERS`] helper.
fn calls_a_shared_writer(source: &Source, functions: &HashSet<String>) -> bool {
    SHARED_WRITERS.iter().any(|(_, helper)| source.calls(functions, helper))
}

/// Rows a source with `god_p95_all` in it names and that compare no rounds: one measure a
/// side, or no `god_p95_all` of their own (the source's line format holds it for others).
const NO_ROUNDS: &[(&str, &str)] = &[
    ("v2.pr05e.random_replay", "a fixed count of checks, no god_p95_all"),
    ("v2.pr05e.cold_continuation", "one byte count a side, no god_p95_all"),
    ("v2.pr05f.equal_entry", "a count of operations, 0 at both sizes"),
    ("v2.pr05d.origin_state_ops", "one count of operations a side"),
    ("v2.pr05d.removed_origin_batch", "one count of operations a side"),
    ("v2.pr05c.replay_frame", "one replay's largest frame a side"),
    ("v2.pr05c.replay_open_hold", "one round, against an absolute bound"),
    ("v2.pr05c.single_encode", "one count of encodes a side"),
    ("v2.pr05c.walk_rss", "a diagnostic line that names the row, no measure"),
    ("v2.pr04.chat_stopped_reader", "one peak resident rise a side, each in its own process"),
];

/// A gate that keeps the best of several rounds hides a round that did different work from
/// the rest (cmux#43438's replay append read 0.995x on rounds that returned early). A source
/// that writes `god_p95_all` for a row calls `gate_rounds::report` on the way to that line:
/// in a function that reaches the row's name ([`Source::reaches`]) or one those call. A row
/// written through a [`SHARED_WRITERS`] helper is read the same way, in its caller's source,
/// and the helper itself must report.
#[test]
fn a_best_of_rounds_row_reports_its_rounds() {
    for (file, helper) in SHARED_WRITERS {
        let path = Path::new(env!("CARGO_MANIFEST_DIR")).join(file);
        let text = fs::read_to_string(&path).unwrap_or_else(|e| panic!("{path:?}: {e}"));
        assert!(text.contains("god_p95_all"), "{helper} in {file} writes no god_p95_all");
        let source = Source::read(&text);
        let helper_and_callees = source.called_from(HashSet::from([helper.to_string()]));
        assert!(
            source.reports_rounds(&helper_and_callees),
            "{helper} in {file} writes rows' god_p95_all without gate_rounds::report"
        );
    }
    let registry_home = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/v2_gate_home.rs");
    let mut files: Vec<PathBuf> = names_in_sources().into_iter().map(|(_, file)| file).collect();
    files.sort();
    files.dedup();
    let (mut checked, mut shared) = (0, 0);
    let mut silent = Vec::new();
    for file in files.iter().filter(|file| **file != registry_home) {
        let text = fs::read_to_string(file).unwrap_or_else(|e| panic!("{file:?}: {e}"));
        let source = Source::read(&text);
        let all_functions = source.functions.iter().map(|(f, _, _)| f.clone()).collect();
        let through_shared = calls_a_shared_writer(&source, &all_functions);
        if !text.contains("god_p95_all") && !through_shared {
            continue;
        }
        for row in GATE_ROWS {
            let reached = source.reaches(row.name);
            if reached.is_empty() {
                continue;
            }
            checked += 1;
            let exempt = NO_ROUNDS.iter().any(|(name, _)| *name == row.name);
            let called = source.called_from(reached);
            if calls_a_shared_writer(&source, &called) {
                shared += 1;
            }
            let reports = source.reports_rounds(&called) || calls_a_shared_writer(&source, &called);
            if !exempt && !reports {
                silent.push(format!("{} in {file:?}", row.name));
            }
        }
    }
    assert!(checked >= 20, "the scan read too few rows that write god_p95_all: {checked}");
    assert!(shared >= 1, "the scan read no row written through a shared writer");
    assert!(
        silent.is_empty(),
        "these rows write god_p95_all and no function on the way to their line calls \
             gate_rounds::report, so a round that did different work stays hidden: {silent:#?}"
    );
}

#[test]
fn a_row_reports_its_rounds_through_the_functions_it_calls() {
    let text = [
        "fn emit(name: &str, small: &[Vec<u128>], god: &[Vec<u128>]) {",
        "    gate_rounds::report(name, &[(\"small\", small), (\"god\", god)]);",
        "    line(name, \"god_p95_all\");",
        "}",
        "",
        "fn measure(name: &str) {",
        "    emit(name, &small, &god);",
        "}",
        "",
        "fn first_gate() {",
        "    measure(\"v2.pr99.through_two\");",
        "}",
        "",
        "fn second_gate() {",
        "    line(\"v2.pr99.silent\", \"god_p95_all\");",
        "}",
    ]
    .join("\n");
    let source = Source::read(&text);
    let reports = |row: &str| source.reports_rounds(&source.called_from(source.reaches(row)));
    assert!(reports("v2.pr99.through_two"));
    assert!(!reports("v2.pr99.silent"));
}

#[test]
fn a_row_written_through_a_shared_writer_reports_its_rounds() {
    let text = [
        "fn gate() {",
        "    let name = \"v2.pr99.through_list_daemon\";",
        "    let (small, god, god_all) = emit_with_all(name, &small_wall, &god_wall, \"ns\");",
        "}",
        "",
        "fn other_gate() {",
        "    line(\"v2.pr99.silent\", \"ns\");",
        "}",
    ]
    .join("\n");
    let source = Source::read(&text);
    let shared = |row: &str| calls_a_shared_writer(&source, &source.reaches(row));
    assert!(shared("v2.pr99.through_list_daemon"));
    assert!(!shared("v2.pr99.silent"));
    assert!(!source.reports_rounds(&source.reaches("v2.pr99.through_list_daemon")));
}

/// The gate script's `gate_runner` cases: each `.gates` group word and the runner it starts.
fn gate_groups(script: &str) -> HashMap<String, String> {
    let entry = regex::Regex::new(r"^\s*([a-z0-9-]+)\) echo (run_[a-z_]+) ;;$").unwrap();
    script
        .lines()
        .filter_map(|line| entry.captures(line))
        .map(|found| (found[1].to_owned(), found[2].to_owned()))
        .collect()
}

/// One `.gates` line, read the way the gate script reads it: `None` when it is blank after its
/// `#` comment is cut, else its group and filter, or `Err` for a line of another shape. A
/// filter is one word of `[A-Za-z0-9_]`, so `core mod::gate` is refused here and by the script.
fn gate_line(line: &str) -> Result<Option<(&str, &str)>, ()> {
    let words: Vec<&str> = line.split('#').next().unwrap_or_default().split_whitespace().collect();
    match words[..] {
        [] => Ok(None),
        [group, filter]
            if filter.bytes().all(|byte| byte.is_ascii_alphanumeric() || byte == b'_') =>
        {
            Ok(Some((group, filter)))
        }
        _ => Err(()),
    }
}

#[test]
fn a_gate_line_is_read_with_the_scripts_shape_rule() {
    assert_eq!(gate_line(""), Ok(None));
    assert_eq!(gate_line("# a comment"), Ok(None));
    assert_eq!(
        gate_line("core replay_append_gate # row 5c"),
        Ok(Some(("core", "replay_append_gate")))
    );
    assert_eq!(gate_line("book v2_pr03d_"), Ok(Some(("book", "v2_pr03d_"))));
    for bad in ["core", "core mod::gate", "core two words", "core gate-name"] {
        assert_eq!(gate_line(bad), Err(()), "{bad:?}");
    }
}

/// Every line of `scripts/cmux-next/v2-gates.d`, as its file's prefix (`pr03d` for
/// `pr03d.gates`) and the target and filter the script runs it with. A line is `GROUP FILTER`
/// after a `#` comment is cut; a line of another shape or an unknown group fails by name.
fn gate_lines() -> Vec<(String, Target, String)> {
    let root = repository();
    let script_path = root.join("scripts/cmux-next/run-v2-gates.sh");
    let script =
        fs::read_to_string(&script_path).unwrap_or_else(|e| panic!("{script_path:?}: {e}"));
    let groups = gate_groups(&script);
    assert_eq!(groups.len(), 6, "the gate script's group table: {groups:?}");
    let dir = root.join("scripts/cmux-next/v2-gates.d");
    let mut files: Vec<PathBuf> = fs::read_dir(&dir)
        .unwrap_or_else(|e| panic!("{dir:?}: {e}"))
        .map(|entry| entry.unwrap().path())
        .collect();
    files.sort();
    let mut lines = Vec::new();
    for file in files {
        let prefix = file.file_stem().and_then(|stem| stem.to_str()).unwrap_or_default();
        assert!(
            file.extension().is_some_and(|extension| extension == "gates"),
            "{file:?} is not a .gates file"
        );
        let text = fs::read_to_string(&file).unwrap_or_else(|e| panic!("{file:?}: {e}"));
        for (number, line) in text.lines().enumerate() {
            let Some((group, filter)) = gate_line(line).unwrap_or_else(|()| {
                panic!("{file:?}:{}: a gate line is GROUP FILTER: {line:?}", number + 1)
            }) else {
                continue;
            };
            let runner = groups
                .get(group)
                .unwrap_or_else(|| panic!("{file:?}:{}: {group} is not a gate group", number + 1));
            lines.push((prefix.to_owned(), runner.clone(), filter.to_owned()));
        }
    }
    let as_script: String =
        lines.iter().map(|(_, runner, filter)| format!("{runner} {filter}\n")).collect();
    let filters = gate_script_filters(&format!("{script}\n{as_script}"));
    assert_eq!(filters.len(), lines.len(), "the script itself names gates: {filters:?}");
    lines
        .into_iter()
        .zip(filters)
        .map(|((prefix, _, _), (target, filter))| (prefix, target, filter))
        .collect()
}

/// Every source that names a gate, with its text.
fn gate_sources() -> Vec<(PathBuf, String)> {
    let mut files: Vec<PathBuf> = names_in_sources().into_iter().map(|(_, file)| file).collect();
    files.sort();
    files.dedup();
    files
        .into_iter()
        .map(|file| {
            let text = fs::read_to_string(&file).unwrap_or_else(|e| panic!("{file:?}: {e}"));
            (file, text)
        })
        .collect()
}

/// Whether a gate line starts a test that writes this row.
fn runs_row(sources: &[(&Path, Source<'_>)], row: &str, target: &Target, filter: &str) -> bool {
    sources.iter().any(|(file, source)| {
        target_of(file).as_ref() == Some(target)
            && source.reaches(row).iter().any(|function| function.contains(filter))
    })
}

/// A row is marked measured only when the nightly can write it. The nightly starts the gate
/// tests the script's lines name and no others, so a marked row whose test has no line fails
/// the nightly's "no measure" step on base, after the pull request that marked it merged.
#[test]
fn a_measured_row_has_a_gate_script_line() {
    let filters: Vec<(Target, String)> =
        gate_lines().into_iter().map(|(_, target, filter)| (target, filter)).collect();
    assert!(filters.len() >= 20, "the scan read too few gate script lines: {filters:?}");
    let texts = gate_sources();
    let sources: Vec<(&Path, Source<'_>)> =
        texts.iter().map(|(file, text)| (file.as_path(), Source::read(text))).collect();
    for row in GATE_ROWS.iter().filter(|row| row.measured) {
        let mut run = false;
        let mut writers = Vec::new();
        for (file, source) in &sources {
            let mut reached: Vec<String> = source.reaches(row.name).into_iter().collect();
            if reached.is_empty() {
                continue;
            }
            reached.sort();
            let target = target_of(file);
            run |= filters.iter().any(|(of, filter)| {
                target.as_ref() == Some(of)
                    && reached.iter().any(|function| function.contains(filter.as_str()))
            });
            writers.push((target, reached));
        }
        assert!(
            run,
            "{} is marked measured and no line of scripts/cmux-next/v2-gates.d runs a test \
                 that writes it: add a line to its prefix's .gates file for one of {writers:?}",
            row.name
        );
    }
}

/// A gate line goes in the file of the prefix whose row its test writes, so a PR that adds a
/// gate edits only its own row's file. A gate that writes no row (one that prints what it
/// observes) goes in the file of the prefix its filter spells.
#[test]
fn a_gate_line_runs_a_test_that_writes_a_row_of_its_files_prefix() {
    let texts = gate_sources();
    let sources: Vec<(&Path, Source<'_>)> =
        texts.iter().map(|(file, text)| (file.as_path(), Source::read(text))).collect();
    let spelled = |filter: &str, prefix: &str| {
        regex::Regex::new(&format!(r"(^|[^a-z0-9]){prefix}($|[^a-z0-9])")).unwrap().is_match(filter)
    };
    for (prefix, target, filter) in gate_lines() {
        let rows = rows::GROUPS
            .iter()
            .find(|(group, _)| *group == prefix)
            .unwrap_or_else(|| panic!("{prefix}.gates names no row file in rows/mod.rs"))
            .1;
        if rows.iter().any(|row| runs_row(&sources, row.name, &target, &filter)) {
            continue;
        }
        let writes_a_row =
            GATE_ROWS.iter().any(|row| runs_row(&sources, row.name, &target, &filter));
        assert!(
            !writes_a_row && spelled(&filter, &prefix),
            "v2-gates.d/{prefix}.gates runs {filter} on {target:?}, and no test it starts \
                 writes a v2.{prefix}.* row: move the line to the file of the row it writes"
        );
    }
}

/// Each row file holds only its own prefix's rows, and every file in `rows/` is listed.
#[test]
fn a_row_file_holds_only_its_own_prefix() {
    let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("benches/v2/rows");
    let mut files: Vec<String> = fs::read_dir(&dir)
        .unwrap_or_else(|e| panic!("{dir:?}: {e}"))
        .map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned())
        .filter(|name| name != "mod.rs")
        .collect();
    files.sort();
    let mut listed: Vec<String> =
        rows::GROUPS.iter().map(|(prefix, _)| format!("{prefix}.rs")).collect();
    listed.sort();
    assert_eq!(files, listed, "every file in benches/v2/rows is listed in rows/mod.rs");
    for (prefix, rows) in rows::GROUPS {
        for row in *rows {
            assert!(
                row.name.starts_with(&format!("v2.{prefix}.")),
                "rows/{prefix}.rs holds {}: move it to the file of its own prefix",
                row.name
            );
        }
    }
    assert_eq!(GATE_ROWS.len(), rows::GROUPS.iter().map(|(_, rows)| rows.len()).sum::<usize>());
}

/// The shared registry file holds no row, so two v2 PRs never edit one file for their rows:
/// a row put back in `mod.rs` fails here by its line.
#[test]
fn the_registry_file_holds_no_row() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("benches/v2");
    let row = regex::Regex::new(r"^\s*GateRow \{").unwrap();
    for file in [root.join("mod.rs"), root.join("rows/mod.rs")] {
        let text = fs::read_to_string(&file).unwrap_or_else(|e| panic!("{file:?}: {e}"));
        for (number, line) in text.lines().enumerate() {
            assert!(
                !row.is_match(line),
                "{file:?}:{} holds a gate row: put it in rows/PREFIX.rs",
                number + 1
            );
        }
    }
}

#[test]
fn a_gate_script_line_is_read_with_its_runners_crate_and_target() {
    let script = [
        "run_lib() {",
        "  run cargo test --release -p acpmux-book --lib \"$1\" -- --ignored --nocapture",
        "}",
        "",
        "run_connection() {",
        "  run cargo test --profile gate -p acpmux --test v2_connection \"$1\" -- --ignored",
        "}",
        "",
        "gates() {",
        "  run_lib first_gate",
        "  run_connection second_gate",
        "  run_nothing third_gate",
        "}",
        "run_group gates gates",
    ]
    .join("\n");
    let line = |package: &str, target: &str, filter: &str| {
        ((package.to_owned(), target.to_owned()), filter.to_owned())
    };
    assert_eq!(
        gate_script_filters(&script),
        [line("acpmux-book", "lib", "first_gate"), line("acpmux", "v2_connection", "second_gate")]
    );
}

#[test]
fn a_row_is_reached_through_the_functions_around_its_name_and_their_callers() {
    let text = [
        "fn write_rows(out: &Path) {",
        "    measure(out, \"v2.pr99.through_a_helper\");",
        "}",
        "",
        "fn empty() {}",
        "",
        "mod tests {",
        "    #[test]",
        "    fn first_gate() {",
        "        fn inner() {",
        "            measure(out, \"v2.pr99.inner\");",
        "        }",
        "        write_rows(out);",
        "    }",
        "",
        "    async fn other_gate() {",
        "        rewrite_rows(out);",
        "    }",
        "}",
    ]
    .join("\n");
    let source = Source::read(&text);
    let reached = |row: &str| {
        let mut functions: Vec<String> = source.reaches(row).into_iter().collect();
        functions.sort();
        functions
    };
    assert_eq!(reached("v2.pr99.through_a_helper"), ["first_gate", "write_rows"]);
    assert_eq!(reached("v2.pr99.inner"), ["first_gate", "inner"]);
    assert!(reached("v2.pr99.absent").is_empty());
}

fn change_row() -> &'static GateRow {
    GATE_ROWS.iter().find(|row| row.name == "v2.pr05.summary_change").unwrap()
}

fn sample(small: f64, god: f64, all: Option<f64>) -> Measure {
    Measure {
        name: change_row().name.to_owned(),
        small_p95: small,
        god_p95: god,
        god_p95_all: all,
        unit: Some("ns".to_owned()),
        gate_failed: false,
    }
}

#[test]
fn summary_change_uses_each_of_its_own_bounds() {
    let row = change_row();
    assert_eq!(measured_row(row, &sample(1800.0, 3470.0, Some(5000.0)))["status"], "ok");
    assert_eq!(measured_row(row, &sample(1000.0, 3701.0, Some(5000.0)))["status"], "red");
    assert_eq!(measured_row(row, &sample(1000.0, 3000.0, Some(6201.0)))["status"], "red");
    assert_eq!(measured_row(row, &sample(10000.0, 10001.0, Some(10001.0)))["status"], "red");
}

#[test]
fn best_of_rounds_rows_require_the_all_sample_measure() {
    assert!(
        merge_measures(&[sample(1000.0, 3000.0, None)], &[])
            .unwrap_err()
            .contains("requires god_p95_all")
    );
    assert!(merge_measures(&[sample(1000.0, 3000.0, Some(5000.0))], &[]).is_ok());
}

#[test]
fn page_byte_rows_enforce_block_ratio_and_absolute_read_budget() {
    for name in ["first", "middle", "last"] {
        let row =
            GATE_ROWS.iter().find(|row| row.name == format!("v2.pr05b.page_{name}_bytes")).unwrap();
        let measure = |small, god| Measure {
            name: row.name.to_owned(),
            small_p95: small,
            god_p95: god,
            god_p95_all: None,
            unit: Some("bytes".to_owned()),
            gate_failed: false,
        };
        assert_eq!(measured_row(row, &measure(4000.0, 47_870.0))["status"], "ok");
        assert_eq!(measured_row(row, &measure(1000.0, 15_401.0))["status"], "red");
        let maximum = row.god_max.unwrap();
        assert_eq!(measured_row(row, &measure(10_000.0, maximum))["status"], "ok");
        assert_eq!(measured_row(row, &measure(10_000.0, maximum + 1.0))["status"], "red");
    }
}

#[test]
fn terminal_page_rows_enforce_phase_ratio_and_absolute_time_budget() {
    for name in ["v2.pr05b.page_last", "v2.pr05b.page_last_filter"] {
        let row = GATE_ROWS.iter().find(|row| row.name == name).unwrap();
        assert_eq!(measured_row(row, &sample(1000.0, 14_900.0, Some(24_800.0)))["status"], "ok");
        assert_eq!(measured_row(row, &sample(1000.0, 14_901.0, Some(24_800.0)))["status"], "red");
        assert_eq!(measured_row(row, &sample(1000.0, 14_900.0, Some(24_801.0)))["status"], "red");
        assert_eq!(
            measured_row(row, &sample(100_000.0, 400_001.0, Some(400_001.0)))["status"],
            "red"
        );
    }
}

#[test]
fn parser_rejects_invalid_optional_all_sample_values() {
    for invalid in [json!(-1), json!("not a number"), Value::Null] {
        let value = json!({"name": change_row().name, "small_p95": 1,
            "god_p95": 1, "god_p95_all": invalid, "unit": "ns"});
        assert!(parse_measure(value, Path::new("fixture")).is_err());
    }
}
