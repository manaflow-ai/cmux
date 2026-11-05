//! `acpmux who-else [FILE]... [--topic T] [--session S] [--since DUR]`: the other live and
//! recent sessions, on this machine and its peers, that read or edited the same files, sit in
//! the same worktree or on the same branch, or work on the same topic (`_acpmux/who_else`,
//! `hub/touched.rs`). With nothing named it asks for the session it runs in
//! (`ACPMUX_SESSION_ID`): the files that session edited lately, its worktree and its branch.
//! Outside a session, for the current folder.

use anyhow::Result;
use serde_json::{Map, Value, json};

use crate::cli::output::print_json;
use crate::rpc::method;

/// The session an agent's shell runs in.
const SESSION_ENV: &str = "ACPMUX_SESSION_ID";

#[derive(clap::Args, Debug, Clone, Default)]
pub struct WhoElseArgs {
    /// Files to look for (relative to the current folder). None: what the session edited lately.
    pub files: Vec<String>,
    /// Also match sessions whose name, title or last prompt share most of these words.
    #[arg(long)]
    pub topic: Option<String>,
    /// Ask for this session (name or id) instead of the one this shell runs in.
    #[arg(long)]
    pub session: Option<String>,
    /// How far back a touch counts: `30m`, `6h`, `2d` (default 1d).
    #[arg(long)]
    pub since: Option<String>,
    /// This machine only: do not ask its peers.
    #[arg(long)]
    pub local: bool,
}

/// `30m`, `6h`, `2d`, `90s` or bare seconds, as ms.
pub(crate) fn duration_ms(text: &str) -> Result<u64> {
    let text = text.trim();
    let (n, unit) = text.split_at(text.find(|c: char| !c.is_ascii_digit()).unwrap_or(text.len()));
    let n: u64 =
        n.parse().map_err(|_| anyhow::anyhow!("--since: {text:?} is not like 30m, 6h or 2d"))?;
    let per_unit: u64 = match unit {
        "" | "s" => 1,
        "m" => 60,
        "h" => 3600,
        "d" => 86_400,
        _ => anyhow::bail!("--since: {text:?} is not like 30m, 6h or 2d"),
    };
    n.checked_mul(per_unit)
        .and_then(|secs| secs.checked_mul(1000))
        .ok_or_else(|| anyhow::anyhow!("--since: {text:?} is too long"))
}

/// The request params for `args`, in folder `cwd`, from a shell whose session is `env_session`.
fn params(args: &WhoElseArgs, cwd: &std::path::Path, env_session: Option<String>) -> Result<Value> {
    let mut p = Map::new();
    p.insert("cwd".into(), json!(cwd.to_string_lossy()));
    if !args.files.is_empty() {
        p.insert("files".into(), json!(args.files));
    }
    if let Some(t) = &args.topic {
        p.insert("topic".into(), json!(t));
    }
    if let Some(s) = args.session.clone().or(env_session).filter(|s| !s.is_empty()) {
        p.insert("sessionId".into(), json!(s));
        // Its own folder, not the shell's, unless files are named relative to the shell's.
        if args.files.is_empty() {
            p.remove("cwd");
        }
    }
    if let Some(s) = &args.since {
        p.insert("sinceMs".into(), json!(duration_ms(s)?));
    }
    if args.local {
        p.insert("peers".into(), json!(false));
    }
    Ok(Value::Object(p))
}

/// What `who-else` prints for an answer.
pub(crate) fn text(answer: &Value) -> String {
    let list = |k: &str| answer.get(k).and_then(Value::as_array).into_iter().flatten();
    let rows: Vec<&Value> = list("sessions").collect();
    let mut out = String::new();
    if rows.is_empty() {
        out.push_str("No other session works on these.\n");
    } else {
        for line in list("lines").filter_map(Value::as_str) {
            out.push_str(line);
            out.push('\n');
        }
        if let Some(more) = answer.get("more").and_then(Value::as_u64).filter(|n| *n > 0) {
            out.push_str(&format!("+{more} more (--json lists the first 50 in full)\n"));
        }
    }
    for u in list("unreached") {
        let field = |k: &str| u.get(k).and_then(Value::as_str);
        let host = field("host").unwrap_or("?");
        out.push_str(&format!("(not asked: {host}: {})\n", field("error").unwrap_or("")));
    }
    out
}

pub async fn run(args: WhoElseArgs, json_out: bool) -> Result<()> {
    let cwd = std::env::current_dir()?;
    let p = params(&args, &cwd, std::env::var(SESSION_ENV).ok())?;
    let client = crate::daemon::connect(true).await?;
    let answer = client.request(method::MUX_WHO_ELSE, p).await?;
    if json_out {
        print_json(&answer);
    } else {
        print!("{}", text(&answer));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn nothing_named_in_a_session_asks_for_that_session_not_the_shells_folder() {
        let args = WhoElseArgs::default();
        let p = params(&args, std::path::Path::new("/w"), Some("s1".into())).unwrap();
        assert_eq!(p, json!({"sessionId": "s1"}));
        let files = WhoElseArgs { files: vec!["a.rs".into()], local: true, ..Default::default() };
        let p = params(&files, std::path::Path::new("/w"), Some("s1".into())).unwrap();
        assert_eq!(p, json!({"cwd": "/w", "files": ["a.rs"], "sessionId": "s1", "peers": false}));
        let p = params(&args, std::path::Path::new("/w"), None).unwrap();
        assert_eq!(p, json!({"cwd": "/w"}));
    }

    #[test]
    fn since_reads_minutes_hours_and_days() {
        assert_eq!(duration_ms("30m").unwrap(), 30 * 60_000);
        assert_eq!(duration_ms("2d").unwrap(), 2 * 86_400_000);
        assert!(duration_ms("soon").is_err());
    }

    #[test]
    fn a_since_too_long_to_count_is_refused_not_wrapped() {
        assert!(duration_ms("999999999999999999d").is_err());
        assert!(duration_ms("18446744073709551615").is_err());
    }

    #[test]
    fn an_empty_answer_says_so_and_names_unreached_peers() {
        let a = json!({"sessions": [], "unreached": [{"host": "big-red", "error": "no answer in 5 s"}]});
        assert_eq!(
            text(&a),
            "No other session works on these.\n(not asked: big-red: no answer in 5 s)\n"
        );
    }
}
