//! How the host runs a Chief `watch` command when glaeda-gh is on the host:
//! a watch never polls GitHub itself (the user, 2026-11-19: "glaeda-gh wait
//! pr|run|comment is in everyone's agent rules, runs off webhooks so it spends
//! no quota ... are we using this properly too?"). A watch with `until` re-runs
//! its command every 15 s, so one `gh api .../actions/runs/N` watch spent 240
//! REST calls an hour (w43, w45). [`route`] turns every GitHub wait it can
//! name into one `glaeda-gh wait run|pr|comment` (the daemon is the host's one
//! poller and hears GitHub's webhooks through the build controller), a file or
//! pid check or sleep loop into `glaeda-gh wait file|pid`, and refuses a GitHub
//! poll it cannot say as one wait, naming the command to use instead.

use regex::Regex;

/// What the host runs for a watch.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Route {
    /// The command as the Chief gave it.
    Keep,
    /// This command and `until` instead.
    Rewrite {
        command: String,
        until: Option<String>,
    },
    /// Not started: it would poll GitHub; the text says what to run instead.
    Refuse(String),
}

/// The line a rewritten GitHub read prints after its wait ended, so the watch
/// ends then even when the Chief's `until` does not match the final state.
pub const WAIT_ENDED: &str = "watch: the GitHub wait ended";

/// How far back a comment wait looks: a reply that came just before the
/// watch started still counts; the PR's older history does not.
const COMMENT_SINCE: &str = "60m";

/// How the host runs `command` with `until` for `timeout_seconds`, given
/// glaeda-gh is on the host (the caller checks that).
pub fn route(command: &str, until: Option<&str>, timeout_seconds: u64) -> Route {
    if let Some(command) = crate::watch::quota_safe(command, until, timeout_seconds) {
        return Route::Rewrite {
            command,
            until: until.map(str::to_owned),
        };
    }
    let Some(tokens) = tokenize(command) else {
        return Route::Keep;
    };
    let simple = simple_commands(&tokens);
    let looped = simple.iter().any(|c| {
        c.words
            .first()
            .is_some_and(|w| matches!(w.text.as_str(), "while" | "until" | "for" | "do"))
            || command_name(&c.words).is_some_and(|(name, _)| name == "sleep")
    });
    let reads: Vec<GhRead> = simple.iter().filter_map(|c| gh_read(&c.words)).collect();
    if reads.is_empty() {
        return file_or_pid(command, &tokens, &simple, until, looped, timeout_seconds);
    }
    let t = timeout_seconds;
    let targets: Vec<&Target> = {
        let mut seen: Vec<&Target> = Vec::new();
        for target in reads.iter().filter_map(|r| r.target.as_ref()) {
            if !seen.contains(&target) {
                seen.push(target);
            }
        }
        seen
    };
    let unnamed = reads.iter().any(|r| r.target.is_none());
    let blocking = reads.iter().any(|r| r.blocks);
    // One read with no until runs once: no poll.
    if !(looped || blocking || until.is_some()) {
        return Route::Keep;
    }
    if targets.len() > 1 {
        return Route::Refuse(format!(
            "watch: refused, this would poll GitHub for {} targets; start one watch per run, PR or comment, each a `glaeda-gh wait` ({}), so its daemon waits for every session on this host",
            targets.len(),
            targets
                .iter()
                .map(|target| format!("`{}`", target.wait(pr_default(target), t)))
                .collect::<Vec<_>>()
                .join(", ")
        ));
    }
    if looped || unnamed {
        let how = match targets.first() {
            Some(target) => format!(
                "watch `{}` with no until (it exits when the wait ends), then read the result once",
                target.wait(pr_default(target), t)
            ),
            None => "find the run's id or the PR's number once, then watch `glaeda-gh wait run OWNER/REPO/RUN_ID` or `glaeda-gh wait pr OWNER/REPO#N` with no until".to_owned(),
        };
        let why = if looped {
            "a shell loop re-reads GitHub on its own"
        } else {
            "this GitHub read names no single run, PR or comment with its OWNER/REPO, so it would be re-read every 15 s"
        };
        return Route::Refuse(format!(
            "watch: refused, {why}; {how}. Never a polling loop, `gh run watch` or `gh pr checks --watch`: glaeda-gh's daemon is the one poller on this host and hears GitHub's webhooks"
        ));
    }
    let Some(target) = targets.first().copied() else {
        return Route::Keep;
    };
    if blocking {
        // `gh run watch` / `gh pr checks --watch`: the wait itself.
        let wait = target.wait(pr_default(target), t);
        return match until {
            None => Route::Rewrite {
                command: wait,
                until: None,
            },
            Some(u) => Route::Rewrite {
                command: format!("{wait}; echo \"{WAIT_ENDED} (glaeda-gh exit $?)\""),
                until: Some(or_ended(u)),
            },
        };
    }
    // One read: it polls only with an until; without one it runs once.
    let Some(u) = until else {
        return Route::Keep;
    };
    let Some(wait) = target.wait_for(u, t) else {
        return Route::Keep;
    };
    Route::Rewrite {
        command: format!(
            "{wait} >/dev/null 2>&1; rc=$?\n{command}\necho \"{WAIT_ENDED} (glaeda-gh exit $rc)\""
        ),
        until: Some(or_ended(u)),
    }
}

/// A PR's wait waits for every check to finish; other waits take no `--until`.
fn pr_default(target: &Target) -> Option<&'static str> {
    (target.kind == Kind::Pr).then_some("done")
}

/// `until`, or the line a rewritten wait prints when it ended.
fn or_ended(until: &str) -> String {
    format!("(?:{until})|^{}", regex::escape(WAIT_ENDED))
}

/// What one GitHub read waits on.
#[derive(Clone, Debug, PartialEq, Eq)]
enum Kind {
    Run,
    Pr,
    Comment,
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct Target {
    kind: Kind,
    repo: String,
    number: String,
}

/// Words that name a state still in progress: an `until` naming one waits
/// for something glaeda has no wait for (a run to start), so it is kept.
const PENDING_WORDS: &[&str] = &[
    "queued",
    "progress",
    "pending",
    "waiting",
    "requested",
    "blocked",
    "behind",
    "unknown",
    "expected",
    "started",
    "running",
];

/// Words of a finished run or check, or a merge: an `until` naming one waits
/// for what glaeda waits for.
const DONE_WORDS: &[&str] = &[
    "completed",
    "success",
    "fail",
    "cancel",
    "conclusion",
    "skipped",
    "timed_out",
    "neutral",
    "pass",
    "error",
    "done",
    "clean",
    "unstable",
    "green",
    "merged",
    "closed",
    "true",
    "false",
];

impl Target {
    /// The glaeda-gh wait for this target.
    fn wait(&self, pr_until: Option<&str>, seconds: u64) -> String {
        match self.kind {
            Kind::Run => format!(
                "glaeda-gh wait run {}/{} --timeout {seconds}",
                self.repo, self.number
            ),
            Kind::Pr => format!(
                "glaeda-gh wait pr {}#{}{} --timeout {seconds}",
                self.repo,
                self.number,
                pr_until
                    .map(|u| format!(" --until {u}"))
                    .unwrap_or_default()
            ),
            Kind::Comment => format!(
                "glaeda-gh wait comment {}#{} --since {COMMENT_SINCE} --timeout {seconds}",
                self.repo, self.number
            ),
        }
    }

    /// The wait before a polled read whose output must match `until`, or None
    /// when that `until` is not something glaeda waits for.
    fn wait_for(&self, until: &str, seconds: u64) -> Option<String> {
        let re = Regex::new(until).ok()?;
        let lower = until.to_ascii_lowercase();
        let pending = PENDING_WORDS
            .iter()
            .any(|w| lower.contains(w) || re.is_match(w) || re.is_match(&w.to_ascii_uppercase()));
        match self.kind {
            Kind::Comment => Some(format!(
                "glaeda-gh wait comment {}#{} --match {} --since {COMMENT_SINCE} --timeout {seconds}",
                self.repo,
                self.number,
                quote(until)
            )),
            _ if pending || !DONE_WORDS.iter().any(|w| lower.contains(w)) => None,
            Kind::Run => Some(self.wait(None, seconds)),
            Kind::Pr => {
                let merge = ["merged", "closed", "true"]
                    .iter()
                    .any(|w| lower.contains(w));
                Some(self.wait(Some(if merge { "merged" } else { "done" }), seconds))
            }
        }
    }
}

/// One `gh` call that reads GitHub.
struct GhRead {
    /// What it reads, when it names one run, PR or comment list with its repo.
    target: Option<Target>,
    /// `gh run watch` or `gh pr checks --watch`: it polls on its own.
    blocks: bool,
}

/// The GitHub read `words` makes, when it is one.
fn gh_read(words: &[Word]) -> Option<GhRead> {
    let (name, at) = command_name(words)?;
    if name != "gh" && !name.ends_with("/gh") {
        return None;
    }
    let args: Vec<&str> = words[at + 1..].iter().map(|w| w.text.as_str()).collect();
    let repo_flag = args
        .windows(2)
        .find(|w| w[0] == "-R" || w[0] == "--repo")
        .map(|w| w[1].to_owned())
        .or_else(|| {
            args.iter()
                .find_map(|a| a.strip_prefix("--repo=").map(str::to_owned))
        });
    let positional = |from: usize| {
        let mut skip = false;
        for a in args.iter().skip(from) {
            if skip {
                skip = false;
                continue;
            }
            if a.starts_with('-') {
                // Flags of gh run/pr/issue that take a value.
                skip = matches!(
                    *a,
                    "-R" | "--repo"
                        | "--json"
                        | "-q"
                        | "--jq"
                        | "-t"
                        | "--template"
                        | "-i"
                        | "--interval"
                        | "--job"
                        | "-j"
                        | "--attempt"
                );
                continue;
            }
            return Some(*a);
        }
        None
    };
    let sub = (args.first().copied()?, args.get(1).copied().unwrap_or(""));
    let flag = |f: &str| {
        args.iter()
            .any(|a| *a == f || a.starts_with(&format!("{f}=")))
    };
    match sub {
        ("api", _) => {
            let method = args
                .windows(2)
                .find(|w| w[0] == "-X" || w[0] == "--method")
                .map(|w| w[1].to_ascii_uppercase());
            if method.is_some_and(|m| m != "GET") {
                return None;
            }
            let path = positional(1)?;
            if path == "graphql" {
                return Some(GhRead {
                    target: None,
                    blocks: false,
                });
            }
            Some(GhRead {
                target: api_target(path),
                blocks: false,
            })
        }
        ("run", "view" | "watch") => {
            let id = positional(2);
            let target = id.and_then(|id| {
                url_target(id).or_else(|| {
                    repo_flag.clone().filter(|_| digits(id)).map(|repo| Target {
                        kind: Kind::Run,
                        repo,
                        number: id.to_owned(),
                    })
                })
            });
            let target = target.filter(|t| ok_repo(&t.repo));
            Some(GhRead {
                target,
                blocks: sub.1 == "watch",
            })
        }
        ("run" | "pr" | "issue", "list" | "status") => Some(GhRead {
            target: None,
            blocks: false,
        }),
        ("pr" | "issue", "view" | "checks") => {
            let n = positional(2);
            let comments = flag("--comments")
                || args
                    .windows(2)
                    .any(|w| w[0] == "--json" && w[1].split(',').any(|f| f == "comments"));
            let target = n.and_then(|n| {
                url_target(n)
                    .map(|mut t| {
                        if comments {
                            t.kind = Kind::Comment;
                        }
                        t
                    })
                    .or_else(|| {
                        repo_flag.clone().filter(|_| digits(n)).map(|repo| Target {
                            kind: if comments { Kind::Comment } else { Kind::Pr },
                            repo,
                            number: n.to_owned(),
                        })
                    })
            });
            let target = target.filter(|t| ok_repo(&t.repo));
            Some(GhRead {
                target,
                blocks: sub.1 == "checks" && (flag("--watch") || flag("-w")),
            })
        }
        _ => None,
    }
}

/// The run, PR or comment list a REST path (`repos/O/R/...`) names.
fn api_target(path: &str) -> Option<Target> {
    let path = path.trim_start_matches('/');
    let path = path.split('?').next().unwrap_or(path);
    let parts: Vec<&str> = path.trim_end_matches('/').split('/').collect();
    let target = match parts.as_slice() {
        ["repos", o, r, "actions", "runs", n]
        | ["repos", o, r, "actions", "runs", n, "jobs" | "attempts", ..] => (Kind::Run, *o, *r, *n),
        ["repos", o, r, "pulls", n] | ["repos", o, r, "pulls", n, "reviews" | "commits"] => {
            (Kind::Pr, *o, *r, *n)
        }
        ["repos", o, r, "issues" | "pulls", n, "comments"] => (Kind::Comment, *o, *r, *n),
        _ => return None,
    };
    let (kind, owner, name, number) = target;
    let t = Target {
        kind,
        repo: format!("{owner}/{name}"),
        number: number.to_owned(),
    };
    (digits(number) && ok_repo(&t.repo)).then_some(t)
}

/// The run or PR a github.com URL names.
fn url_target(word: &str) -> Option<Target> {
    let path = word.strip_prefix("https://github.com/")?;
    let parts: Vec<&str> = path.trim_end_matches('/').split(['/', '#', '?']).collect();
    let (kind, owner, name, number) = match parts.as_slice() {
        [o, r, "actions", "runs", n, ..] => (Kind::Run, *o, *r, *n),
        [o, r, "pull" | "issues", n, ..] => (Kind::Pr, *o, *r, *n),
        _ => return None,
    };
    digits(number).then(|| Target {
        kind,
        repo: format!("{owner}/{name}"),
        number: number.to_owned(),
    })
}

fn digits(s: &str) -> bool {
    !s.is_empty() && s.chars().all(|c| c.is_ascii_digit())
}

fn ok_repo(repo: &str) -> bool {
    repo.split('/').count() == 2
        && repo.split('/').all(|p| !p.is_empty())
        && repo
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '/' | '-' | '_' | '.'))
}

/// A file or pid check, or a sleep loop on one, as a glaeda-gh wait.
fn file_or_pid(
    command: &str,
    tokens: &[Token],
    simple: &[Simple],
    until: Option<&str>,
    looped: bool,
    seconds: u64,
) -> Route {
    if looped {
        return sleep_loop(command, tokens, seconds).map_or(Route::Keep, |command| {
            Route::Rewrite {
                command,
                until: until.map(str::to_owned),
            }
        });
    }
    // `CHECK && REST` (or `kill -0 PID || REST`), re-run every 15 s with an until.
    if until.is_none() || simple.len() < 2 {
        return Route::Keep;
    }
    let first = &simple[0];
    let Some(Token::Op(op)) = tokens.get(first.end) else {
        return Route::Keep;
    };
    let rest = command[tokens_start(tokens, first.end + 1)..].trim();
    let check = check_of(&first.words);
    let wait = match (check, op.as_str()) {
        (Some(Check::Ready(wait)), "&&") => wait,
        (Some(Check::Alive(pid)), "||") => format!("glaeda-gh wait pid {pid}"),
        _ => return Route::Keep,
    };
    Route::Rewrite {
        command: format!("{wait} --timeout {seconds} && {rest}"),
        until: until.map(str::to_owned),
    }
}

/// `until CHECK; do sleep N; done; REST` (or `while ! CHECK`, `while kill -0
/// PID`) as `glaeda-gh wait ...; REST`.
fn sleep_loop(command: &str, tokens: &[Token], seconds: u64) -> Option<String> {
    let word = |i: usize| match tokens.get(i) {
        Some(Token::Word(w)) => Some(w.text.as_str()),
        _ => None,
    };
    let keyword = word(0)?;
    let negated = word(1) == Some("!");
    let cond_from = if negated { 2 } else { 1 };
    let cond_end = (cond_from..tokens.len())
        .find(|&i| matches!(&tokens[i], Token::Op(o) if o == ";" || o == "\n"))?;
    let cond: Vec<Word> = tokens[cond_from..cond_end]
        .iter()
        .filter_map(|t| match t {
            Token::Word(w) => Some(w.clone()),
            Token::Op(_) => None,
        })
        .collect();
    if tokens[cond_from..cond_end]
        .iter()
        .any(|t| matches!(t, Token::Op(_)))
    {
        return None;
    }
    // `do sleep N; done`
    let mut i = cond_end + 1;
    if word(i) != Some("do") || word(i + 1) != Some("sleep") {
        return None;
    }
    i += 2;
    if word(i).is_none_or(|n| n.trim_end_matches(['s', 'm']).parse::<f64>().is_err()) {
        return None;
    }
    i += 1;
    if !matches!(tokens.get(i), Some(Token::Op(o)) if o == ";" || o == "\n")
        || word(i + 1) != Some("done")
    {
        return None;
    }
    i += 2;
    let wait = match (keyword, negated, check_of(&cond)?) {
        ("until", false, Check::Ready(wait)) | ("while", true, Check::Ready(wait)) => wait,
        ("while", false, Check::Alive(pid)) => format!("glaeda-gh wait pid {pid}"),
        _ => return None,
    };
    let wait = format!("{wait} --timeout {seconds}");
    match tokens.get(i) {
        None => Some(wait),
        Some(Token::Op(op)) if matches!(op.as_str(), ";" | "\n" | "&&") => {
            let rest = command[tokens_start(tokens, i + 1)..].trim();
            Some(if rest.is_empty() {
                wait
            } else {
                format!("{wait}{} {rest}", if op == "&&" { " &&" } else { ";" })
            })
        }
        _ => None,
    }
}

/// What a file or pid check waits for.
enum Check {
    /// It passes once this glaeda-gh wait (without its timeout) is ready.
    Ready(String),
    /// `kill -0 PID`: it passes while the process lives.
    Alive(String),
}

/// The check `words` makes: `test -s|-e|-f P`, `[ ... ]`, `grep -q PAT FILE`,
/// `kill -0 PID`; redirections are ignored.
fn check_of(words: &[Word]) -> Option<Check> {
    let words: Vec<&str> = words
        .iter()
        .map(|w| w.text.as_str())
        .filter(|w| !is_redirection(w))
        .collect();
    match words.as_slice() {
        ["test", flag, path] | ["[", flag, path, "]"] | ["[[", flag, path, "]]"] => {
            let exists = match *flag {
                "-s" => "",
                "-e" | "-f" => " --exists",
                _ => return None,
            };
            Some(Check::Ready(format!(
                "glaeda-gh wait file {}{exists}",
                quote(path)
            )))
        }
        ["kill", "-0", pid] if digits(pid) => Some(Check::Alive((*pid).to_owned())),
        ["grep", flags, pattern, file] if flags.starts_with('-') => {
            let letters = flags.trim_start_matches('-');
            if !letters.contains('q') || !letters.chars().all(|c| matches!(c, 'q' | 'E' | 's')) {
                return None;
            }
            // A basic regex reads + ? ( ) { } | literally; glaeda's are extended.
            if !letters.contains('E') && pattern.contains(['+', '?', '(', ')', '{', '}', '|', '\\'])
            {
                return None;
            }
            Some(Check::Ready(format!(
                "glaeda-gh wait file {} --contains {}",
                quote(file),
                quote(pattern)
            )))
        }
        _ => None,
    }
}

fn is_redirection(word: &str) -> bool {
    let rest = word.trim_start_matches(|c: char| c.is_ascii_digit() || c == '&');
    rest.starts_with('>') || rest.starts_with('<')
}

/// The command's name (after `timeout N`, `env`, shell keywords such as `do`, and VAR=value words) and its
/// index in `words`.
fn command_name(words: &[Word]) -> Option<(&str, usize)> {
    let mut i = 0;
    while let Some(w) = words.get(i) {
        let t = w.text.as_str();
        if !w.quoted && t.contains('=') && !t.starts_with('-') && !t.starts_with('=') {
            i += 1;
        } else if t == "timeout" {
            i += 2;
        } else if matches!(
            t,
            "env"
                | "exec"
                | "!"
                | "nohup"
                | "do"
                | "then"
                | "else"
                | "elif"
                | "if"
                | "while"
                | "until"
                | "{"
        ) {
            i += 1;
        } else {
            return Some((t, i));
        }
    }
    None
}

/// A shell word: its unquoted text, where it starts in the command, and
/// whether any of it was quoted.
#[derive(Clone, Debug)]
struct Word {
    text: String,
    start: usize,
    quoted: bool,
}

#[derive(Clone, Debug)]
enum Token {
    Word(Word),
    /// `&&`, `||`, `;`, `|`, `&`, a newline, `(`, `)`, `$(` or a backtick.
    Op(String),
}

/// One simple command: its words, and the index of the token that ends it.
struct Simple {
    words: Vec<Word>,
    end: usize,
}

fn simple_commands(tokens: &[Token]) -> Vec<Simple> {
    let mut out = Vec::new();
    let mut words = Vec::new();
    for (i, token) in tokens.iter().enumerate() {
        match token {
            Token::Word(w) => words.push(w.clone()),
            Token::Op(_) => {
                if !words.is_empty() {
                    out.push(Simple {
                        words: std::mem::take(&mut words),
                        end: i,
                    });
                }
            }
        }
    }
    if !words.is_empty() {
        out.push(Simple {
            words,
            end: tokens.len(),
        });
    }
    out
}

/// Where token `i` starts in the command (its end when there is none).
fn tokens_start(tokens: &[Token], i: usize) -> usize {
    tokens[i..]
        .iter()
        .find_map(|t| match t {
            Token::Word(w) => Some(w.start),
            Token::Op(_) => None,
        })
        .unwrap_or(usize::MAX)
}

/// Splits `command` into words and operators the way sh does for these
/// checks: quotes and backslashes, no expansion. A command substitution in
/// double quotes stays one word. None for an unterminated quote.
fn tokenize(command: &str) -> Option<Vec<Token>> {
    let mut tokens = Vec::new();
    let chars: Vec<(usize, char)> = command.char_indices().collect();
    let mut i = 0;
    let mut word: Option<Word> = None;
    let flush = |word: &mut Option<Word>, tokens: &mut Vec<Token>| {
        if let Some(w) = word.take() {
            tokens.push(Token::Word(w));
        }
    };
    while i < chars.len() {
        let (at, c) = chars[i];
        let next = chars.get(i + 1).map(|&(_, c)| c);
        let op = match (c, next) {
            ('&', Some('&')) | ('|', Some('|')) | ('$', Some('(')) => {
                Some(command[at..at + 2].to_owned())
            }
            (';', Some(';')) => Some(";;".to_owned()),
            (';' | '|' | '&' | '\n' | '(' | ')' | '`', _) => Some(c.to_string()),
            _ => None,
        };
        // `2>&1` and `>&2` are redirections, not background operators.
        let in_redirection = c == '&'
            && word
                .as_ref()
                .is_some_and(|w| w.text.ends_with('>') || w.text.ends_with('<'));
        if let Some(op) = op.filter(|_| !in_redirection) {
            flush(&mut word, &mut tokens);
            i += op.chars().count();
            tokens.push(Token::Op(op));
            continue;
        }
        if c.is_whitespace() {
            flush(&mut word, &mut tokens);
            i += 1;
            continue;
        }
        let w = word.get_or_insert_with(|| Word {
            text: String::new(),
            start: at,
            quoted: false,
        });
        match c {
            '\'' => {
                w.quoted = true;
                i += 1;
                loop {
                    let (_, q) = *chars.get(i)?;
                    i += 1;
                    if q == '\'' {
                        break;
                    }
                    w.text.push(q);
                }
            }
            '"' => {
                w.quoted = true;
                i += 1;
                loop {
                    let (_, q) = *chars.get(i)?;
                    i += 1;
                    match q {
                        '"' => break,
                        '\\' => {
                            let (_, e) = *chars.get(i)?;
                            i += 1;
                            if !matches!(e, '"' | '\\' | '$' | '`') {
                                w.text.push('\\');
                            }
                            w.text.push(e);
                        }
                        _ => w.text.push(q),
                    }
                }
            }
            '\\' => {
                if let Some(&(_, e)) = chars.get(i + 1) {
                    w.text.push(e);
                }
                i += 2;
            }
            _ => {
                w.text.push(c);
                i += 1;
            }
        }
    }
    flush(&mut word, &mut tokens);
    Some(tokens)
}

/// `s` as one sh word.
fn quote(s: &str) -> String {
    if !s.is_empty()
        && s.chars().all(|c| {
            c.is_ascii_alphanumeric()
                || matches!(c, '/' | '.' | '_' | '-' | ':' | '=' | '+' | ',' | '@')
        })
    {
        s.to_owned()
    } else {
        format!("'{}'", s.replace('\'', r"'\''"))
    }
}
