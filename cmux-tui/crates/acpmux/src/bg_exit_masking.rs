//! A background command whose exit may not be its own (`bg_start`, `hub/bg_tasks.rs`
//! `bg_view`, `bg_run::outcome`). The coordinator, 2026-11-11: "A rule in briefs only helps
//! agents who read it. A check in the tool covers every helper, even one whose brief forgot it."
//! Three times that day a test run failed (exit 1) while its task's end message said exit 0,
//! because the command was `cmux-ci test -- ... > log 2>&1; echo "cmux-ci exit $?" >> log`: the
//! shell's exit is its last stage's, the echo's.
//!
//! [`check`] reads the command string, never runs it, and names one of three shapes:
//!
//! - the top level ends on `echo`, `printf`, `true`, `:` or `exit 0` after an earlier `;` or
//!   newline list ran a real command whose failure nothing handled (no `set -e`, no `|| exit N`);
//! - the last list ends `|| true` (or `|| :`, `|| echo ...`, `|| exit 0`);
//! - a pipeline (`a | b`, `a |& b`) in the last list, or anywhere after `set -e`, with a real
//!   command left of a pipe and no `set -o pipefail` (or `set -euo pipefail`, `bash -o pipefail`)
//!   before it: its exit is the last stage's.
//!
//! `bash -c '...'` / `sh -c "..."` as the last command is read again: its payload's shape is the
//! command's, with the options before `-c` (`-e`, `-o pipefail`, `-euo pipefail`) as its start.
//!
//! It is conservative: it warns only on a string it parsed. Quotes (`'`, `"`, `$'...'`),
//! backslashes, `$(...)`, backticks, `${...}`, comments and redirections are read; a heredoc's body
//! is skipped up to its delimiter. Anything else it does not follow gives no warning at all: a
//! subshell or `{ ...; }` group, `if`/`for`/`while`/`case`/functions, `[[ ]]`, `!`, `time`, a
//! `bash -c` payload that is not a plain literal (it holds `$` or a backtick), an unbalanced quote
//! or a heredoc with no end. It does not know what a script file or a wrapper (`timeout`, `env`,
//! `cmux-ci test -- bash -c ...`) does with an exit, and it never refuses a command: the task runs
//! as given, and only its start result and its end message carry the warning.

/// The reason a command's exit may not be its own, e.g. `last stage is echo`; `None` when none of
/// the module's shapes is there, or the string is not one it reads with confidence.
pub fn check(command: &str) -> Option<String> {
    check_from(command, State::default(), 0)
}

/// How deep `bash -c` payloads are read.
const DEPTH_MAX: usize = 4;

#[derive(Clone, Copy, Default)]
struct State {
    pipefail: bool,
    errexit: bool,
}

fn check_from(command: &str, mut st: State, depth: usize) -> Option<String> {
    let lists = parse(&lex(command)?)?;
    let (final_list, earlier) = lists.split_last()?;
    if final_list.background {
        return None;
    }
    let mut hidden_real = false;
    for list in earlier {
        if let Some(why) = st.walk(list, false) {
            return Some(why);
        }
        if !st.errexit && list.runs_real() && !list.handles_failure() {
            hidden_real = true;
        }
    }
    if let Some(why) = st.walk(final_list, true) {
        return Some(why);
    }
    let [cmd] = final_list.chain.last()?.as_slice() else { return None };
    if final_list.ops.last() == Some(&AndOr::Or)
        && let Some(what) = cmd.masks()
    {
        return Some(format!("|| {what} hides a failure"));
    }
    if final_list.chain.len() == 1
        && hidden_real
        && let Some(what) = cmd.masks()
    {
        return Some(format!("last stage is {what}"));
    }
    if depth < DEPTH_MAX
        && let Some((payload, start)) = cmd.shell_payload()
    {
        return check_from(&payload, start, depth.saturating_add(1));
    }
    None
}

impl State {
    /// Follows a list's `set` commands and names a pipeline whose exit is not its own: one in
    /// the last list, or anywhere under `set -e`.
    fn walk(&mut self, list: &List, last: bool) -> Option<String> {
        for p in &list.chain {
            if let [only] = p.as_slice()
                && only.name() == Some("set")
            {
                self.apply_set(&only.args());
                continue;
            }
            let Some((end, left)) = p.split_last() else { continue };
            if !left.is_empty()
                && !self.pipefail
                && (last || self.errexit)
                && left.iter().any(|c| !c.pipe_source())
            {
                let end = end.name().map_or("the last stage's".to_owned(), |n| format!("{n}'s"));
                return Some(format!("pipeline without pipefail, so the exit is {end}"));
            }
        }
        None
    }

    /// `set -e`, `set -o pipefail`, `set -euo pipefail`, `set +o pipefail`, ...
    fn apply_set(&mut self, args: &[Option<&str>]) {
        let mut it = args.iter();
        while let Some(arg) = it.next() {
            let Some(arg) = arg else { continue };
            let on = arg.starts_with('-');
            if !on && !arg.starts_with('+') {
                continue;
            }
            for c in arg.chars().skip(1) {
                match c {
                    'e' => self.errexit = on,
                    'o' => match it.next().copied().flatten() {
                        Some("pipefail") => self.pipefail = on,
                        Some("errexit") => self.errexit = on,
                        _ => {}
                    },
                    _ => {}
                }
            }
        }
    }
}

// ---- lexing ----

#[derive(Debug, Clone, PartialEq)]
enum Tok {
    Word(Word),
    Redir,
    Semi,
    Newline,
    Amp,
    And,
    Or,
    Pipe,
    Paren,
}

#[derive(Debug, Clone, PartialEq)]
struct Word {
    raw: String,
    /// Its value once quotes are removed, when it holds no expansion.
    lit: Option<String>,
}

fn is_meta(c: char) -> bool {
    matches!(c, ' ' | '\t' | '\n' | ';' | '&' | '|' | '(' | ')' | '<' | '>')
}

/// A cursor over the command's characters; every read is checked, so no input panics.
struct Src {
    s: Vec<char>,
    i: usize,
}

impl Src {
    fn at(&self, k: usize) -> Option<char> {
        self.s.get(self.i.checked_add(k)?).copied()
    }

    fn peek(&self) -> Option<char> {
        self.at(0)
    }

    fn bump(&mut self, n: usize) {
        self.i = self.i.saturating_add(n);
    }

    fn text(&self, from: usize) -> String {
        self.s.get(from..self.i).unwrap_or_default().iter().collect()
    }

    /// Past the next `close`; `None` when there is none.
    fn past(&mut self, close: char, escapes: bool) -> Option<()> {
        loop {
            match self.peek()? {
                '\\' if escapes => self.bump(2),
                c if c == close => {
                    self.bump(1);
                    return Some(());
                }
                _ => self.bump(1),
            }
        }
    }

    /// One line, without its newline (which it steps past).
    fn line(&mut self) -> String {
        let from = self.i;
        while self.peek().is_some_and(|c| c != '\n') {
            self.bump(1);
        }
        let line = self.text(from);
        self.bump(1);
        line
    }
}

/// The command as tokens; `None` for what it does not read (module docs).
fn lex(command: &str) -> Option<Vec<Tok>> {
    let mut src = Src { s: command.chars().collect(), i: 0 };
    let mut out = Vec::new();
    // Heredocs whose body starts after the next newline: (delimiter, strip leading tabs).
    let mut heredocs: Vec<(String, bool)> = Vec::new();
    let mut want_delim: Option<bool> = None;
    while let Some(c) = src.peek() {
        let next = src.at(1);
        match c {
            ' ' | '\t' => src.bump(1),
            '\\' if next == Some('\n') => src.bump(2),
            '#' => {
                while src.peek().is_some_and(|c| c != '\n') {
                    src.bump(1);
                }
            }
            '\n' => {
                out.push(Tok::Newline);
                src.bump(1);
                for (delim, strip) in heredocs.drain(..) {
                    loop {
                        src.peek()?;
                        let line = src.line();
                        let line = if strip { line.trim_start_matches('\t') } else { &line };
                        if line == delim {
                            break;
                        }
                    }
                }
            }
            ';' if matches!(next, Some(';' | '&')) => return None,
            ';' => {
                out.push(Tok::Semi);
                src.bump(1);
            }
            '&' => match next {
                Some('&') => {
                    out.push(Tok::And);
                    src.bump(2);
                }
                Some('>') => {
                    out.push(Tok::Redir);
                    src.bump(if src.at(2) == Some('>') { 3 } else { 2 });
                }
                _ => {
                    out.push(Tok::Amp);
                    src.bump(1);
                }
            },
            '|' => {
                out.push(if next == Some('|') { Tok::Or } else { Tok::Pipe });
                src.bump(if matches!(next, Some('|' | '&')) { 2 } else { 1 });
            }
            '(' | ')' => {
                out.push(Tok::Paren);
                src.bump(1);
            }
            '<' | '>' if next == Some('(') => {
                // Process substitution: one opaque word.
                let from = src.i;
                src.bump(1);
                skip_balanced(&mut src)?;
                out.push(Tok::Word(Word { raw: src.text(from), lit: None }));
            }
            '<' | '>' => {
                let (len, heredoc) = redir_len(&src);
                if let Some(strip) = heredoc {
                    want_delim = Some(strip);
                }
                out.push(Tok::Redir);
                src.bump(len);
            }
            c if c.is_ascii_digit() && fd_digits(&src).is_some() => {
                // A fd number before a redirection (`2>`): the redirection follows.
                src.bump(fd_digits(&src)?);
            }
            _ => {
                let word = lex_word(&mut src)?;
                if let Some(strip) = want_delim.take() {
                    heredocs.push((word.lit.clone()?, strip));
                }
                out.push(Tok::Word(word));
            }
        }
    }
    if !heredocs.is_empty() || want_delim.is_some() {
        return None;
    }
    Some(out)
}

/// The redirection operator's length at the cursor, and for a heredoc whether it strips tabs.
fn redir_len(src: &Src) -> (usize, Option<bool>) {
    match (src.at(0), src.at(1), src.at(2)) {
        (Some('<'), Some('<'), Some('<')) => (3, None),
        (Some('<'), Some('<'), Some('-')) => (3, Some(true)),
        (Some('<'), Some('<'), _) => (2, Some(false)),
        (Some('<'), Some('>' | '&'), _) | (Some('>'), Some('>' | '&' | '|'), _) => (2, None),
        _ => (1, None),
    }
}

/// How many digits start here when a redirection follows them (`2>`), else `None`.
fn fd_digits(src: &Src) -> Option<usize> {
    let mut k = 0;
    while src.at(k).is_some_and(|c| c.is_ascii_digit()) {
        k = k.saturating_add(1);
    }
    matches!(src.at(k), Some('<' | '>')).then_some(k)
}

/// One word: its raw text and its literal value.
fn lex_word(src: &mut Src) -> Option<Word> {
    let from = src.i;
    let mut lit = String::new();
    let mut expands = false;
    while let Some(c) = src.peek().filter(|&c| !is_meta(c)) {
        match c {
            '\\' => {
                match src.at(1)? {
                    '\n' => {}
                    c => lit.push(c),
                }
                src.bump(2);
            }
            '\'' => {
                src.bump(1);
                let start = src.i;
                src.past('\'', false)?;
                lit.push_str(&src.text(start));
                lit.pop();
            }
            '"' => {
                src.bump(1);
                loop {
                    match src.peek()? {
                        '"' => break,
                        '\\' => {
                            let next = src.at(1)?;
                            if !matches!(next, '$' | '`' | '"' | '\\' | '\n') {
                                lit.push('\\');
                            }
                            if next != '\n' {
                                lit.push(next);
                            }
                            src.bump(2);
                        }
                        '$' | '`' => {
                            expands = true;
                            skip_expansion(src)?;
                        }
                        c => {
                            lit.push(c);
                            src.bump(1);
                        }
                    }
                }
                src.bump(1);
            }
            '$' | '`' => {
                expands = true;
                skip_expansion(src)?;
            }
            c => {
                lit.push(c);
                src.bump(1);
            }
        }
    }
    Some(Word { raw: src.text(from), lit: (!expands).then_some(lit) })
}

/// Past an expansion at the cursor (`$name`, `$?`, `$(...)`, `$((...))`, `${...}`, `$'...'`,
/// a backtick).
fn skip_expansion(src: &mut Src) -> Option<()> {
    if src.peek()? == '`' {
        src.bump(1);
        return src.past('`', true);
    }
    match src.at(1) {
        Some('(') => {
            src.bump(1);
            skip_balanced(src)
        }
        Some('{') => {
            src.bump(2);
            src.past('}', false)
        }
        Some('\'') => {
            src.bump(2);
            src.past('\'', true)
        }
        _ => {
            src.bump(1);
            Some(())
        }
    }
}

/// Past the `)` that closes the `(` at the cursor, minding quotes inside.
fn skip_balanced(src: &mut Src) -> Option<()> {
    let mut depth = 0usize;
    loop {
        match src.peek()? {
            '(' => depth = depth.saturating_add(1),
            ')' => {
                depth = depth.saturating_sub(1);
                if depth == 0 {
                    src.bump(1);
                    return Some(());
                }
            }
            '\\' => src.bump(1),
            '\'' => {
                src.bump(1);
                src.past('\'', false)?;
                continue;
            }
            '"' => {
                src.bump(1);
                src.past('"', true)?;
                continue;
            }
            _ => {}
        }
        src.bump(1);
    }
}

// ---- parsing ----

#[derive(Debug, PartialEq)]
enum AndOr {
    And,
    Or,
}

/// One simple command's words, redirections and their targets left out.
#[derive(Debug, Default)]
struct Cmd {
    words: Vec<Word>,
}

type Pipeline = Vec<Cmd>;

/// Pipelines joined by `&&` / `||`, ended by `;`, `&` or a newline.
#[derive(Debug, Default)]
struct List {
    chain: Vec<Pipeline>,
    ops: Vec<AndOr>,
    background: bool,
}

const RESERVED: [&str; 22] = [
    "if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case", "esac",
    "function", "select", "{", "}", "[[", "]]", "!", "time", "coproc", "((",
];

/// Ends the command into its pipeline; an empty one (`| |`, `; ;`) is not read.
fn end_cmd(cmd: &mut Cmd, pipe: &mut Pipeline) -> Option<()> {
    if cmd.words.is_empty() {
        return None;
    }
    pipe.push(std::mem::take(cmd));
    Some(())
}

fn parse(toks: &[Tok]) -> Option<Vec<List>> {
    let mut lists = Vec::new();
    let mut list = List::default();
    let mut pipe: Pipeline = Vec::new();
    let mut cmd = Cmd::default();
    let mut target = false;
    // After `&&`, `||` or `|` a newline continues the line.
    let mut continues = false;
    for t in toks {
        if target && !matches!(t, Tok::Word(_)) {
            return None;
        }
        let blank = cmd.words.is_empty() && pipe.is_empty() && list.chain.is_empty();
        match t {
            Tok::Word(_) if target => {
                target = false;
                continues = false;
            }
            Tok::Word(w) => {
                if cmd.words.iter().all(Cmd::assignment)
                    && w.lit.as_deref().is_some_and(|l| RESERVED.contains(&l))
                {
                    return None;
                }
                cmd.words.push(w.clone());
                continues = false;
            }
            Tok::Redir => target = true,
            Tok::Pipe => {
                end_cmd(&mut cmd, &mut pipe)?;
                continues = true;
            }
            Tok::And | Tok::Or => {
                end_cmd(&mut cmd, &mut pipe)?;
                list.chain.push(std::mem::take(&mut pipe));
                list.ops.push(if *t == Tok::And { AndOr::And } else { AndOr::Or });
                continues = true;
            }
            Tok::Newline if continues || blank => {}
            Tok::Semi | Tok::Newline | Tok::Amp => {
                end_cmd(&mut cmd, &mut pipe)?;
                list.chain.push(std::mem::take(&mut pipe));
                list.background = *t == Tok::Amp;
                lists.push(std::mem::take(&mut list));
            }
            Tok::Paren => return None,
        }
    }
    if target || continues {
        return None;
    }
    if !cmd.words.is_empty() {
        end_cmd(&mut cmd, &mut pipe)?;
        list.chain.push(pipe);
        lists.push(list);
    } else if !pipe.is_empty() || !list.chain.is_empty() {
        return None;
    }
    Some(lists)
}

impl Cmd {
    /// `NAME=value` (or `NAME+=value`) before the command's name.
    fn assignment(w: &Word) -> bool {
        let Some((name, _)) = w.raw.split_once('=') else { return false };
        let name = name.strip_suffix('+').unwrap_or(name);
        let mut chars = name.chars();
        chars.next().is_some_and(|c| c.is_ascii_alphabetic() || c == '_')
            && chars.all(|c| c.is_ascii_alphanumeric() || c == '_')
    }

    /// The words from its name on; empty for a command of only assignments.
    fn from_name(&self) -> &[Word] {
        let at = self.words.iter().position(|w| !Self::assignment(w)).unwrap_or(self.words.len());
        self.words.get(at..).unwrap_or_default()
    }

    /// Its name's literal value; `None` for one that expands (`$CMD`) or only assignments.
    fn name(&self) -> Option<&str> {
        self.from_name().first()?.lit.as_deref()
    }

    fn args(&self) -> Vec<Option<&str>> {
        self.from_name().iter().skip(1).map(|w| w.lit.as_deref()).collect()
    }

    /// What it is when it always succeeds and so stands in for the exit before it.
    fn masks(&self) -> Option<String> {
        match self.name()? {
            n @ ("echo" | "printf" | "true" | ":") => Some(n.to_owned()),
            "exit" if self.args() == [Some("0")] => Some("exit 0".to_owned()),
            _ => None,
        }
    }

    /// Setup that is not the work whose exit matters.
    fn setup(&self) -> bool {
        self.from_name().is_empty()
            || matches!(
                self.name(),
                Some(
                    "cd" | "set"
                        | "export"
                        | "unset"
                        | "shopt"
                        | "trap"
                        | "umask"
                        | "alias"
                        | "declare"
                        | "typeset"
                        | "local"
                        | "readonly"
                        | "pushd"
                        | "popd"
                        | "echo"
                        | "printf"
                        | "true"
                        | ":"
                )
            )
    }

    /// A stage left of a pipe whose failure would not matter anyway.
    fn pipe_source(&self) -> bool {
        matches!(self.name(), Some("echo" | "printf" | "cat" | "true" | ":" | "yes"))
    }

    /// `bash -c 'PAYLOAD'` (or `sh`): the payload when it is a plain literal, and the state its
    /// options start it in (`-e`, `-o pipefail`, `-euo pipefail`).
    fn shell_payload(&self) -> Option<(String, State)> {
        let name = self.name()?;
        if !matches!(name.rsplit('/').next(), Some("bash" | "sh")) {
            return None;
        }
        let mut st = State::default();
        let args = self.args();
        let mut it = args.iter();
        while let Some(arg) = it.next() {
            let flags = (*arg)?.strip_prefix('-')?;
            if flags.is_empty() || !flags.chars().all(|c| c.is_ascii_alphabetic()) {
                return None;
            }
            let mut has_c = false;
            for c in flags.chars() {
                match c {
                    'c' => has_c = true,
                    'e' => st.errexit = true,
                    'o' => match it.next().copied().flatten()? {
                        "pipefail" => st.pipefail = true,
                        "errexit" => st.errexit = true,
                        _ => {}
                    },
                    'l' | 'x' | 'u' | 'v' | 'i' => {}
                    _ => return None,
                }
            }
            if has_c {
                return Some((it.next().copied().flatten()?.to_owned(), st));
            }
        }
        None
    }
}

impl List {
    fn runs_real(&self) -> bool {
        self.chain.iter().flatten().any(|c| !c.setup())
    }

    /// It ends `|| exit N` (N not 0) or `|| exit`, which keeps a failure.
    fn handles_failure(&self) -> bool {
        if self.ops.last() != Some(&AndOr::Or) {
            return false;
        }
        let Some([cmd]) = self.chain.last().map(Vec::as_slice) else { return false };
        matches!(cmd.name(), Some("exit" | "return")) && cmd.masks().is_none()
    }
}

#[cfg(test)]
mod tests {
    use super::check;

    fn warns(cmd: &str) -> String {
        check(cmd).unwrap_or_else(|| panic!("expected a warning for {cmd:?}"))
    }

    fn quiet(cmd: &str) {
        assert_eq!(check(cmd), None, "expected no warning for {cmd:?}");
    }

    /// The 2026-11-11 wrapper: the exit is the echo's, not cmux-ci's.
    #[test]
    fn the_echo_of_its_exit_wrapper_warns() {
        let cmd =
            r#"cmux-ci test -- python3 x.py > /tmp/log 2>&1; echo "cmux-ci exit $?" >> /tmp/log"#;
        assert_eq!(warns(cmd), "last stage is echo");
        assert_eq!(warns("make test\nprintf 'done\\n'"), "last stage is printf");
        assert_eq!(warns("cargo test; true"), "last stage is true");
        assert_eq!(warns("cargo test; exit 0"), "last stage is exit 0");
        assert_eq!(warns("cmux-ci test -- x && echo ok; :"), "last stage is :");
    }

    #[test]
    fn or_true_warns() {
        assert_eq!(warns("cmux-ci test -- x || true"), "|| true hides a failure");
        assert_eq!(warns("cmux-ci test -- x || :"), "|| : hides a failure");
        assert_eq!(warns("cmux-ci test -- x > log 2>&1 || echo failed"), "|| echo hides a failure");
        assert_eq!(warns("set -e; cargo test || exit 0"), "|| exit 0 hides a failure");
    }

    #[test]
    fn a_pipeline_without_pipefail_warns() {
        assert_eq!(
            warns("cmux-ci test -- python3 x.py | tee log"),
            "pipeline without pipefail, so the exit is tee's"
        );
        assert_eq!(
            warns("cargo test 2>&1 |& tail -50"),
            "pipeline without pipefail, so the exit is tail's"
        );
        // set -e alone does not cover a pipe, and it makes an earlier pipeline's exit matter.
        assert_eq!(
            warns("set -e; make | tee log; ls"),
            "pipeline without pipefail, so the exit is tee's"
        );
        // pipefail turned off again.
        assert!(check("set -o pipefail; set +o pipefail; make | tee log").is_some());
    }

    #[test]
    fn a_clean_command_does_not_warn() {
        quiet("set -o pipefail; cmux-ci test -- python3 x.py | tee log");
        quiet("set -euo pipefail; cmux-ci test -- python3 x.py | tee log");
        quiet("set -eo pipefail\ncargo test 2>&1 | tail -50");
        quiet("cmux-ci test -- x");
        quiet("cmux-ci test -- x > log 2>&1");
        quiet("cd /tmp && cargo test");
        quiet("cargo build && echo built");
        quiet("echo hello");
        quiet("echo starting; cargo test");
        quiet("cargo test; rc=$?; echo \"exit $rc\" >> log; exit $rc");
        quiet("cargo test || exit 1; echo ran");
        quiet("set -e; cargo test; echo done");
        quiet("rm -f log || true; cmux-ci test -- x");
        quiet("echo x | cmux-ci test -- y");
        quiet("cat list | xargs cargo test");
        quiet("cargo test; exit");
        quiet("FOO=1 cargo test");
        quiet("");
        quiet("# just a comment\ncargo test # trailing");
    }

    /// Quoted operators are words, not operators.
    #[test]
    fn quoted_operators_are_words() {
        quiet(r#"cmux-ci test -- python3 -c 'print(1); exit(0)'"#);
        quiet(r#"git commit -m "fix: a | b; echo" "#);
        quiet(r#"grep -E 'a|b' file"#);
        quiet(r#"echo "a; b" > x; cargo test"#);
        quiet("printf '%s\\n' x\\;y");
        quiet(r#"cargo test --message "$(git log -1 | head -1)""#);
        quiet("cargo test `echo a | tr a b`");
        assert_eq!(warns(r#"cargo test "a|b"; echo 'x; y'"#), "last stage is echo");
    }

    /// A `bash -c` payload is read when it is a literal; one that expands is not.
    #[test]
    fn a_bash_c_payload_is_read_when_literal() {
        assert_eq!(warns(r#"bash -c 'cmux-ci test -- x; echo "exit $?"'"#), "last stage is echo");
        assert_eq!(
            warns("bash -lc \"cargo test | tee log\""),
            "pipeline without pipefail, so the exit is tee's"
        );
        quiet("bash -o pipefail -c 'cargo test | tee log'");
        quiet("bash -euo pipefail -c 'cargo test | tee log'");
        quiet(r#"bash -c "cargo test $ARGS; echo done""#);
        quiet("bash script.sh");
        quiet("bash -c 'cargo test'");
        assert_eq!(warns("bash -c 'cargo test' || true"), "|| true hides a failure");
    }

    /// A heredoc's body is skipped: its `|` and `;` are text.
    #[test]
    fn heredoc_bodies_are_skipped() {
        quiet("cat > x.py <<'EOF'\nprint('a | b'); exit 0\nEOF\npython3 x.py");
        quiet("python3 - <<-EOF\n\tprint(1) || true\n\tEOF\n");
        assert_eq!(warns("cat > x <<EOF\nhi\nEOF\ncargo test; echo done"), "last stage is echo");
        // No end delimiter: not read.
        quiet("cat <<EOF\ncargo test | tee\n");
    }

    /// What it does not follow gives no warning (module docs).
    #[test]
    fn what_it_cannot_read_does_not_warn() {
        quiet("(cargo test; echo done)");
        quiet("{ cargo test; echo done; }");
        quiet("if cargo test; then echo ok; fi");
        quiet("for i in 1 2; do cargo test; done; echo done");
        quiet("[[ -f x ]] || true");
        quiet("cargo test 'unbalanced");
        quiet("cargo test; echo done &");
        quiet("case x in a) echo;; esac");
    }
}
