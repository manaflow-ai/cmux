//! `acpmux app launch [--machine M] APP [-- ARGS...]` and `acpmux app list [--machine M]`: open an
//! app on this machine or a connected one, and say what can be opened and what runs there
//! (`_acpmux/app_launch`, `_acpmux/app_list`, `server/app_launch.rs`). `cmux app launch --on`
//! runs this.
//!
//! Exit codes: 0 it opened (or listed); 1 the machine answered no (no app by that name, nobody
//! logged in, it did not open, not supported there); 2 the request is wrong; 3 the machine was
//! not reached, refused this caller, or runs an acpmux without app launch. On a failure the last
//! line says what to run next (`--json`: an object with `ok: false`, `reason`, `next`).

use anyhow::Result;
use cmux_json::JsonSet as _;
use serde_json::{Value, json};

use crate::cli::output::print_json;

#[derive(clap::Subcommand, Debug, Clone)]
pub enum AppCmd {
    /// Open an app on this machine or a connected one, in its logged-in session. APP is a name
    /// (`Safari`, `cmux`), a bundle or desktop entry id, or an absolute path. Arguments after
    /// `--` reach the app as they are, never through a shell. It opens behind the window in front
    /// unless `--activate`.
    Launch(LaunchArgs),
    /// The apps a machine can open, the running ones first.
    #[command(alias = "ls")]
    List(ListArgs),
}

#[derive(clap::Args, Debug, Clone, Default)]
pub struct LaunchArgs {
    /// The machine (a connected peer's name); this machine when omitted.
    #[arg(long, visible_alias = "on")]
    pub machine: Option<String>,
    /// Bring the app to the front (default: it opens behind and takes no focus).
    #[arg(long)]
    pub activate: bool,
    /// Open it hidden (macOS).
    #[arg(long)]
    pub hidden: bool,
    /// Open another copy even when one runs (macOS); arguments reach only a new copy.
    #[arg(long = "new")]
    pub new_instance: bool,
    /// How long to wait for its process, in seconds (at most 60; default 15).
    #[arg(long)]
    pub wait: Option<u64>,
    pub app: String,
    /// The app's arguments, after `--`.
    #[arg(last = true)]
    pub args: Vec<String>,
}

#[derive(clap::Args, Debug, Clone, Default)]
pub struct ListArgs {
    /// The machine (a connected peer's name); this machine when omitted.
    #[arg(long, visible_alias = "on")]
    pub machine: Option<String>,
    /// Every app, not only the running ones and the first 40.
    #[arg(long)]
    pub all: bool,
}

/// The request params of a launch.
pub(crate) fn launch_params(args: &LaunchArgs) -> Value {
    let mut p = json!({"app": args.app, "args": args.args});
    for (key, on) in
        [("activate", args.activate), ("hidden", args.hidden), ("new", args.new_instance)]
    {
        if on {
            p.set(key, json!(true));
        }
    }
    if let Some(wait) = args.wait {
        p.set("waitMs", json!(wait.saturating_mul(1000)));
    }
    if let Some(machine) = &args.machine {
        p.set("machine", json!(machine));
    }
    p
}

/// The exit code for a refusal's `reason`.
pub(crate) fn exit_code(reason: &str) -> i32 {
    match reason {
        "app.invalid" => 2,
        "app.unreachable" | "app.not_allowed" | "app.daemon_too_old" => 3,
        _ => 1,
    }
}

pub async fn run(cmd: AppCmd, json_out: bool) -> Result<()> {
    let (m, params, machine) = match &cmd {
        AppCmd::Launch(args) => ("_acpmux/app_launch", launch_params(args), args.machine.clone()),
        AppCmd::List(args) => (
            "_acpmux/app_list",
            args.machine.as_ref().map_or_else(|| json!({}), |m| json!({"machine": m})),
            args.machine.clone(),
        ),
    };
    let client = match crate::daemon::connect(true).await {
        Ok(client) => client,
        Err(e) => {
            return Err(fail(
                json_out,
                "app.unreachable",
                &format!("acpmux's daemon is not running: {e}"),
                "`acpmux daemon start`",
            ));
        }
    };
    let answer = match client.request(m, params).await {
        Ok(answer) => answer,
        Err(e) => {
            let rpc = e.downcast_ref::<crate::client::DaemonError>().map(|d| &d.0);
            let data = rpc.and_then(|r| r.data.as_ref());
            let field = |k: &str| data.and_then(|d| d.get(k)).and_then(Value::as_str);
            let message = rpc.map_or_else(|| e.to_string(), |r| r.message.clone());
            let on = machine.as_deref().map_or_else(String::new, |m| format!(" --on {m}"));
            let (reason, next) = match (field("reason"), rpc.map(|r| r.code)) {
                (Some(reason), _) => {
                    (reason.to_owned(), field("next").unwrap_or_default().to_owned())
                }
                (None, Some(-32601)) => (
                    "app.daemon_too_old".into(),
                    "`acpmux daemon restart` (this daemon is older than app launch)".into(),
                ),
                (None, _) => ("app.failed".into(), format!("`cmux app list{on}`")),
            };
            return Err(fail(json_out, &reason, &message, &next));
        }
    };
    if json_out {
        print_json(&json!({"ok": true, "result": answer}));
        return Ok(());
    }
    match cmd {
        AppCmd::Launch(_) => println!("{}", launch_line(&answer)),
        AppCmd::List(args) => print!("{}", list_text(&answer, args.all)),
    }
    Ok(())
}

/// The error a failed launch or list exits with (`errors::exit_with`): its exit code from
/// `reason`, and what to run next as the last line. Under `--json` the answer object
/// (`{"ok": false, "reason", "error", "next"}`) is on stdout too, for callers that read it there.
fn fail(json_out: bool, reason: &str, message: &str, next: &str) -> anyhow::Error {
    if json_out {
        print_json(&json!({"ok": false, "reason": reason, "error": message, "next": next}));
    }
    let recovery = if next.is_empty() { String::new() } else { format!("next: {next}") };
    let error =
        crate::cli::errors::AppError::new(crate::cli::errors::Code::Runtime, reason, message)
            .with_exit(exit_code(reason))
            .with_data(json!({"reason": reason, "next": next, "recovery": recovery}));
    anyhow::Error::new(error)
}

/// One line for an opened app.
pub(crate) fn launch_line(answer: &Value) -> String {
    let name = answer.pointer("/app/name").and_then(Value::as_str).unwrap_or("the app");
    let machine = answer.get("machine").and_then(Value::as_str).unwrap_or("this machine");
    let pid = answer
        .get("pid")
        .and_then(Value::as_u64)
        .map_or_else(String::new, |p| format!(", pid {p}"));
    let ms = answer.get("ms").and_then(Value::as_u64).unwrap_or(0);
    if answer.get("alreadyRunning").and_then(Value::as_bool) == Some(true) {
        format!("{name} already runs on {machine}{pid}")
    } else {
        format!("opened {name} on {machine}{pid} in {ms} ms")
    }
}

/// The list: the running apps, then the others up to 40 unless `all`.
pub(crate) fn list_text(answer: &Value, all: bool) -> String {
    let machine = answer.get("machine").and_then(Value::as_str).unwrap_or("this machine");
    if answer.get("supported").and_then(Value::as_bool) == Some(false) {
        return format!("app launch is not supported on {machine}'s system yet\n");
    }
    let mut out = String::new();
    if answer.pointer("/session/loggedIn").and_then(Value::as_bool) == Some(false) {
        let why =
            answer.pointer("/session/why").and_then(Value::as_str).unwrap_or("nobody is logged in");
        out.push_str(&format!("{machine}: {why}; nothing can be opened until someone logs in\n"));
    }
    let apps = answer.get("apps").and_then(Value::as_array).cloned().unwrap_or_default();
    let shown =
        if all { apps.len() } else { apps.iter().filter(|a| a["running"] == true).count().max(40) };
    for app in apps.iter().take(shown) {
        let name = app["name"].as_str().unwrap_or_default();
        let id = app["id"].as_str().unwrap_or("-");
        let state = if app["running"] == true {
            let pids: Vec<String> =
                app["pids"].as_array().into_iter().flatten().map(Value::to_string).collect();
            format!("running ({})", pids.join(", "))
        } else {
            String::new()
        };
        out.push_str(&format!("{name:<32} {id:<40} {state}\n").replace("  \n", "\n"));
    }
    if apps.len() > shown {
        out.push_str(&format!("… and {} more (`--all`)\n", apps.len() - shown));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_launchs_arguments_go_as_a_list_never_one_string() {
        let args = LaunchArgs {
            machine: Some("mini".into()),
            app: "Safari".into(),
            args: vec!["$(id)".into(), "a b".into()],
            wait: Some(5),
            ..Default::default()
        };
        assert_eq!(
            launch_params(&args),
            json!({"app": "Safari", "args": ["$(id)", "a b"], "waitMs": 5000, "machine": "mini"})
        );
    }

    #[test]
    fn exit_codes_split_the_answer_from_the_reach() {
        assert_eq!(exit_code("app.not_found"), 1);
        assert_eq!(exit_code("app.no_session"), 1);
        assert_eq!(exit_code("app.invalid"), 2);
        assert_eq!(exit_code("app.unreachable"), 3);
        assert_eq!(exit_code("app.not_allowed"), 3);
        assert_eq!(exit_code("app.daemon_too_old"), 3);
    }

    #[test]
    fn the_lines_say_where_and_what() {
        let opened = json!({"machine": "mini", "app": {"name": "Safari"}, "pid": 42, "ms": 900});
        assert_eq!(launch_line(&opened), "opened Safari on mini, pid 42 in 900 ms");
        let list = json!({"machine": "mini", "supported": true, "session": {"loggedIn": true},
            "apps": [{"name": "Safari", "id": "com.apple.Safari", "running": true, "pids": [42]}]});
        assert!(list_text(&list, false).contains("running (42)"));
    }
}
