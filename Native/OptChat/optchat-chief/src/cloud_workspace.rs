//! The Chief's `cloud_workspace` tool (#25596): a cmux Cloud workspace for a
//! task, that is a Cloud machine named after the task and a workspace on it,
//! filed in the sidebar under the machine's group.
//!
//! The app makes both with its own actions over its control socket, the
//! paths the palette, the sidebar `+` and `cmux cloud` take:
//! `newCloudMachine {name, size}` creates the machine and opens its first
//! workspace when its daemon is up, and `newCloudWorkspace` with
//! `machine:<id>` opens another workspace on a machine that exists. The
//! runs are `script` origin: the app applies its rules for an agent's create
//! (an upgrade card on a plan without Cloud; on a paid plan it makes the
//! machine at once unless the person turned on asking first), so the tool
//! is only for a machine the person asked for.
//!
//! A create can outlast the app's answer (it answers `pending` after 30 s)
//! and a machine joins the list only when its create returns. The tool reads
//! the list first: a machine of the task's name, or a create of that name
//! still on its way (the list's `creating`), is answered and never made
//! again. An app whose list has no `creating` gets the same from the names
//! this host asked for, held for [`CREATING_FOR`].

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use serde_json::{Value, json};

/// The sizes `cmux cloud new-machine --size` takes.
pub use chief_kernel::tools::SIZES;

/// How long a name whose create answered `pending` stays "being made" for
/// an app that does not list its creates: past the app's own retries of a
/// create (70 tries 15 s apart).
pub const CREATING_FOR: Duration = Duration::from_secs(20 * 60);

/// The longest a machine name is (the app takes 64).
const NAME_MAX: usize = 48;

/// Why a run gave no result.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum RunError {
    /// The app answered with a refusal or a failure.
    Refused(String),
    /// The app did not answer (no socket, a timeout): the run may still go on.
    NoAnswer(String),
}

impl std::fmt::Display for RunError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            RunError::Refused(e) => f.write_str(e),
            RunError::NoAnswer(e) => write!(f, "the app did not answer: {e}"),
        }
    }
}

/// One app action run, its `result` fields answered. `key`: the run's
/// idempotency key, so a retry joins or replays it instead of running again.
pub trait AppActions: Send + Sync {
    fn run(
        &self,
        action: &str,
        target: Option<&str>,
        args: Value,
        key: Option<&str>,
    ) -> Result<Value, RunError>;
}

/// The app's control socket (`CMUX_SOCKET_PATH`).
pub struct ControlSocketActions {
    pub socket: PathBuf,
}

/// The longest one run may take: the app answers within its 40 s result
/// deadline, `pending` when the work goes on.
const RUN_TIMEOUT: Duration = Duration::from_secs(60);

impl AppActions for ControlSocketActions {
    fn run(
        &self,
        action: &str,
        target: Option<&str>,
        args: Value,
        key: Option<&str>,
    ) -> Result<Value, RunError> {
        let request = run_request(action, target, args, key);
        let (value, answer) = crate::workspaces::control_reply(&self.socket, &request, RUN_TIMEOUT)
            .map_err(RunError::NoAnswer)?;
        run_result(&value, &answer)
    }
}

/// The run's `result` fields from the app's reply `value` (line `answer`).
/// The app's own `timeout` error is no answer: the run goes on settling under
/// its key (or, `not_run`, never started and left the key free).
pub fn run_result(value: &Value, answer: &str) -> Result<Value, RunError> {
    match crate::workspaces::reply_result(value, answer) {
        Ok(reply) => Ok(reply.get("result").cloned().unwrap_or(Value::Null)),
        Err(e) if value["error"]["code"] == "timeout" => Err(RunError::NoAnswer(e)),
        Err(e) => Err(RunError::Refused(e)),
    }
}

/// The `action.run` request: `script` origin, from the Chief's chat in Home
/// (`CMUX_CALLER_HOME_CHAT`, as the turn's own `cmux` runs say).
pub fn run_request(action: &str, target: Option<&str>, args: Value, key: Option<&str>) -> Value {
    let mut params = json!({
        "action": action,
        "args": args,
        "wait": true,
        "origin": "script",
        "caller": {"home_chat": true},
    });
    if let Some(target) = target {
        params["target"] = json!(target);
    }
    if let Some(key) = key {
        params["idempotency_key"] = json!(key);
    }
    json!({"id": 1, "method": "action.run", "params": params})
}

/// One `cloud_workspace` call.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Request {
    /// The task's short title: the machine's name.
    pub title: String,
    /// `small`, `medium`, `large` or `xlarge`; None: the app's default.
    pub size: Option<String>,
    /// An existing machine (`machine:<id>` or the id): a new workspace on it.
    pub machine: Option<String>,
}

/// The machine name a task title gives: lowercase ASCII letters and digits,
/// with one `-` for every run of anything else; at most 48 characters.
pub fn machine_name(title: &str) -> Result<String, String> {
    let mut name = String::new();
    for c in title.trim().chars() {
        if c.is_ascii_alphanumeric() {
            name.push(c.to_ascii_lowercase());
        } else if !name.is_empty() && !name.ends_with('-') {
            name.push('-');
        }
    }
    name.truncate(NAME_MAX);
    let name = name.trim_end_matches('-').to_owned();
    if name.is_empty() || name == "true" {
        return Err(format!(
            "cloud_workspace: the title {title:?} gives no machine name: use a few words with letters or digits"
        ));
    }
    Ok(name)
}

/// The tool, over the app's actions.
pub struct CloudWorkspaces {
    app: Arc<dyn AppActions>,
    /// Names whose create answered `pending`, and when: for an app whose
    /// list has no `creating`.
    creating: Mutex<HashMap<String, Instant>>,
    /// The attempt of each (machine, title) workspace run: its key's suffix.
    /// It moves on after every run the app answered, so only a retry of a
    /// run with no answer reuses a key (and joins that run).
    attempts: Mutex<HashMap<String, u64>>,
    now: Box<dyn Fn() -> Instant + Send + Sync>,
}

impl CloudWorkspaces {
    pub fn new(app: Arc<dyn AppActions>) -> CloudWorkspaces {
        CloudWorkspaces::with_clock(app, Box::new(Instant::now))
    }

    pub fn with_clock(
        app: Arc<dyn AppActions>,
        now: Box<dyn Fn() -> Instant + Send + Sync>,
    ) -> CloudWorkspaces {
        CloudWorkspaces {
            app,
            creating: Mutex::new(HashMap::new()),
            attempts: Mutex::new(HashMap::new()),
            now,
        }
    }

    /// The app's control socket from the host's env; None without an app
    /// (a Chief started by the CLI or a service, the Cloud Chief's VM).
    pub fn from_env(env: &dyn Fn(&str) -> Option<String>) -> Option<CloudWorkspaces> {
        let socket = env("CMUX_SOCKET_PATH").filter(|s| !s.is_empty())?;
        Some(CloudWorkspaces::new(Arc::new(ControlSocketActions {
            socket: socket.into(),
        })))
    }

    /// Makes the Cloud workspace `request` asks for; the answer starts with
    /// its outcome (done, queued, noop).
    pub fn call(&self, request: &Request) -> Result<String, String> {
        if let Some(size) = &request.size
            && !SIZES.contains(&size.as_str())
        {
            return Err(format!(
                "cloud_workspace: size must be one of {}",
                SIZES.join(", ")
            ));
        }
        match &request.machine {
            Some(machine) => self.on_machine(machine, &request.title),
            None => self.new_machine(request),
        }
    }

    /// Another workspace on machine `machine`. Keyed by the machine, the
    /// title and the attempt: a retry after a run the app did not answer
    /// joins it, never opening a second workspace; any answered run (done,
    /// pending or refused) leaves the next call a fresh run.
    fn on_machine(&self, machine: &str, title: &str) -> Result<String, String> {
        let machine = machine.trim();
        let target = if machine.starts_with("machine:") {
            machine.to_owned()
        } else {
            format!("machine:{machine}")
        };
        let base = machine_name(title)
            .ok()
            .map(|name| format!("optchat-cloud-workspace-{target}-{name}"));
        let attempt = base.as_ref().map(|base| {
            *self
                .attempts
                .lock()
                .expect("attempts")
                .entry(base.clone())
                .or_default()
        });
        // The app takes keys of at most 200 characters.
        let key = base
            .as_ref()
            .zip(attempt)
            .map(|(base, n)| format!("{base}-{n}"))
            .filter(|key| key.len() <= 200);
        let answer = self.app.run(
            "newCloudWorkspace",
            Some(&target),
            json!({}),
            key.as_deref(),
        );
        if let Some(base) = &base
            && !matches!(answer, Err(RunError::NoAnswer(_)))
        {
            *self
                .attempts
                .lock()
                .expect("attempts")
                .entry(base.clone())
                .or_default() += 1;
        }
        let result = answer.map_err(|e| match e {
            RunError::NoAnswer(_) => format!(
                "cloud_workspace: {e}. The workspace may still open: look in the sidebar; a call with the same machine and title joins that run, never opening a second one"
            ),
            RunError::Refused(_) => format!("cloud_workspace: {e}"),
        })?;
        if result["pending"] == true {
            let status = result["status"].as_str().unwrap_or("connecting");
            return Ok(format!(
                "outcome: queued. {target} is {status}: the workspace for {title:?} opens in the sidebar, under that machine, when it is up. Do not call again for it."
            ));
        }
        let Some(workspace) = result["workspace_id"].as_str() else {
            return Err(format!(
                "cloud_workspace: the app opened no workspace on {target}: {result}"
            ));
        };
        Ok(format!(
            "outcome: done. Cloud workspace {workspace} for {title:?} is open on {target}, in the sidebar under that machine. Run its commands with `cmux cloud exec --target {target}`."
        ))
    }

    /// A new machine for the task, unless one of its name exists or is
    /// still being made.
    fn new_machine(&self, request: &Request) -> Result<String, String> {
        let name = machine_name(&request.title)?;
        let list = self
            .app
            .run("cloudListMachines", None, json!({}), None)
            .map_err(|e| format!("cloud_workspace: listing the Cloud machines: {e}"))?;
        if list["account"]["signed_in"] == false {
            return Err(
                "cloud_workspace: cmux Cloud is signed out on this Mac: ask the person to sign in (`cmux cloud sign-in`), then call again"
                    .into(),
            );
        }
        if list["loaded"] != true {
            return Err(
                "cloud_workspace: the app is still loading the Cloud machine list: call again in a minute (making one now could make a second machine)"
                    .into(),
            );
        }
        let named = |entry: &&Value, key: &str| {
            entry[key]
                .as_str()
                .is_some_and(|t| t.eq_ignore_ascii_case(&name))
        };
        let existing = list["machines"]
            .as_array()
            .and_then(|machines| machines.iter().find(|m| named(m, "title")));
        if let Some(machine) = existing {
            self.creating.lock().expect("creating").remove(&name);
            let target = machine["target"].as_str().unwrap_or_default();
            let status = machine["status"].as_str().unwrap_or("unknown");
            return Ok(format!(
                "outcome: noop. Cloud machine {name} ({target}) already exists ({status}); its workspace is in the sidebar under it. For another workspace on it, call cloud_workspace with machine {target}."
            ));
        }
        let now = (self.now)();
        match list["creating"].as_array() {
            // The app lists its creates still on their way: they decide.
            Some(creates) => {
                self.creating.lock().expect("creating").remove(&name);
                if let Some(create) = creates.iter().find(|c| named(c, "name")) {
                    if create["status"] == "failed" {
                        let reason = create["reason"].as_str().unwrap_or("no reason given");
                        return Err(format!(
                            "cloud_workspace: the create of Cloud machine {name} failed ({reason}); it is in the sidebar, where the person can Retry or dismiss it. Tell them; do not make another."
                        ));
                    }
                    return Ok(format!(
                        "outcome: noop. Cloud machine {name} is still being made; its workspace opens in the sidebar when it is up. Never ask for a second one."
                    ));
                }
            }
            // An app that does not: the names this host asked for.
            None => {
                let mut creating = self.creating.lock().expect("creating");
                creating.retain(|_, at| now.duration_since(*at) < CREATING_FOR);
                if let Some(at) = creating.get(&name) {
                    let minutes = now.duration_since(*at).as_secs() / 60;
                    return Ok(format!(
                        "outcome: noop. Cloud machine {name} is still being made (asked {minutes} min ago); it opens in the sidebar when it is up. Never ask for a second one."
                    ));
                }
            }
        }
        let mut args = json!({"name": name});
        if let Some(size) = &request.size {
            args["size"] = json!(size);
        }
        let result = self
            .app
            .run("newCloudMachine", None, args, None)
            .map_err(|e| format!("cloud_workspace: {e}"))?;
        if result["pending"] == true || result["machine_id"].as_str().is_none() {
            self.creating
                .lock()
                .expect("creating")
                .insert(name.clone(), now);
            return Ok(format!(
                "outcome: queued. Cloud machine {name} is being made; its workspace opens in the sidebar when it is up. Call cloud_workspace with the same title later to check; never ask for a second one."
            ));
        }
        let target = result["target"]
            .as_str()
            .map(str::to_owned)
            .unwrap_or_else(|| {
                format!(
                    "machine:{}",
                    result["machine_id"].as_str().unwrap_or_default()
                )
            });
        let workspace = match result["workspace_id"].as_str() {
            Some(id) => format!("its workspace {id} is open"),
            None => "its workspace opens".to_owned(),
        };
        Ok(format!(
            "outcome: done. Cloud machine {name} ({target}) is made and {workspace} in the sidebar under it. Run its commands with `cmux cloud exec --target {target}`."
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// One recorded run: action, target, args, idempotency key.
    type Run = (String, Option<String>, Value, Option<String>);

    /// The app: answers by action, and records each run.
    struct FakeApp {
        answers: Mutex<HashMap<&'static str, Vec<Result<Value, RunError>>>>,
        runs: Mutex<Vec<Run>>,
    }

    impl FakeApp {
        fn new(answers: Vec<(&'static str, Result<Value, RunError>)>) -> Arc<FakeApp> {
            let mut map: HashMap<&'static str, Vec<Result<Value, RunError>>> = HashMap::new();
            for (action, answer) in answers {
                map.entry(action).or_default().push(answer);
            }
            Arc::new(FakeApp {
                answers: Mutex::new(map),
                runs: Mutex::new(Vec::new()),
            })
        }

        fn runs(&self) -> Vec<Run> {
            self.runs.lock().unwrap().clone()
        }
    }

    impl AppActions for FakeApp {
        fn run(
            &self,
            action: &str,
            target: Option<&str>,
            args: Value,
            key: Option<&str>,
        ) -> Result<Value, RunError> {
            self.runs.lock().unwrap().push((
                action.to_owned(),
                target.map(str::to_owned),
                args,
                key.map(str::to_owned),
            ));
            let mut answers = self.answers.lock().unwrap();
            let queue = answers.get_mut(action).expect("an answer for the action");
            if queue.len() > 1 {
                queue.remove(0)
            } else {
                queue[0].clone()
            }
        }
    }

    fn list(machines: Value) -> Result<Value, RunError> {
        Ok(json!({"loaded": true, "machines": machines, "account": {"signed_in": true}}))
    }

    fn request(title: &str) -> Request {
        Request {
            title: title.into(),
            size: None,
            machine: None,
        }
    }

    #[test]
    fn names_follow_the_title() {
        assert_eq!(machine_name("Fix login bug").unwrap(), "fix-login-bug");
        assert_eq!(
            machine_name("  #25596: Chief / Cloud!! ").unwrap(),
            "25596-chief-cloud"
        );
        assert_eq!(machine_name(&"a".repeat(80)).unwrap().len(), NAME_MAX);
        assert!(machine_name("日本語").is_err());
        assert!(machine_name("---").is_err());
    }

    #[test]
    fn a_new_task_makes_a_machine_whose_workspace_opens() {
        let app = FakeApp::new(vec![
            ("cloudListMachines", list(json!([]))),
            (
                "newCloudMachine",
                Ok(json!({"machine_id": "vm-1", "target": "machine:vm-1", "workspace_id": "ws_9"})),
            ),
        ]);
        let tool = CloudWorkspaces::new(app.clone());
        let answer = tool
            .call(&Request {
                size: Some("medium".into()),
                ..request("Fix login bug")
            })
            .unwrap();
        assert!(answer.starts_with("outcome: done."), "{answer}");
        assert!(
            answer.contains("machine:vm-1") && answer.contains("ws_9"),
            "{answer}"
        );
        let runs = app.runs();
        assert_eq!(runs[1].0, "newCloudMachine");
        assert_eq!(
            runs[1].2,
            json!({"name": "fix-login-bug", "size": "medium"})
        );
    }

    #[test]
    fn a_pending_create_is_never_made_twice() {
        let app = FakeApp::new(vec![
            ("cloudListMachines", list(json!([]))),
            (
                "newCloudMachine",
                Ok(json!({"pending": true, "status": "creating"})),
            ),
        ]);
        let start = Instant::now();
        let at = Arc::new(Mutex::new(start));
        let clock = at.clone();
        let tool =
            CloudWorkspaces::with_clock(app.clone(), Box::new(move || *clock.lock().unwrap()));
        let first = tool.call(&request("Fix login bug")).unwrap();
        assert!(first.starts_with("outcome: queued."), "{first}");
        *at.lock().unwrap() = start + Duration::from_secs(120);
        let second = tool.call(&request("fix login bug")).unwrap();
        assert!(
            second.starts_with("outcome: noop.") && second.contains("2 min"),
            "{second}"
        );
        let creates = |app: &FakeApp| {
            app.runs()
                .iter()
                .filter(|r| r.0 == "newCloudMachine")
                .count()
        };
        assert_eq!(creates(&app), 1);
        // Past the window, with the list still not showing it, a call creates again.
        *at.lock().unwrap() = start + CREATING_FOR;
        tool.call(&request("fix login bug")).unwrap();
        assert_eq!(creates(&app), 2);
    }

    #[test]
    fn an_existing_machine_of_the_name_is_not_made_again() {
        let app = FakeApp::new(vec![(
            "cloudListMachines",
            list(
                json!([{"title": "Fix-Login-Bug", "target": "machine:vm-7", "status": "running"}]),
            ),
        )]);
        let tool = CloudWorkspaces::new(app.clone());
        let answer = tool.call(&request("Fix login bug")).unwrap();
        assert!(
            answer.starts_with("outcome: noop.") && answer.contains("machine:vm-7"),
            "{answer}"
        );
        assert!(app.runs().iter().all(|r| r.0 != "newCloudMachine"));
    }

    #[test]
    fn an_unloaded_or_signed_out_list_makes_nothing() {
        for (answer, says) in [
            (
                json!({"loaded": false, "machines": [], "account": {"signed_in": true}}),
                "still loading",
            ),
            (
                json!({"loaded": false, "machines": [], "account": {"signed_in": false}}),
                "signed out",
            ),
        ] {
            let app = FakeApp::new(vec![("cloudListMachines", Ok(answer))]);
            let error = CloudWorkspaces::new(app.clone())
                .call(&request("task"))
                .unwrap_err();
            assert!(error.contains(says), "{error}");
            assert_eq!(app.runs().len(), 1);
        }
    }

    #[test]
    fn a_named_machine_gets_another_workspace() {
        let app = FakeApp::new(vec![(
            "newCloudWorkspace",
            Ok(json!({"machine_id": "vm-2", "workspace_id": "ws_4"})),
        )]);
        let tool = CloudWorkspaces::new(app.clone());
        let answer = tool
            .call(&Request {
                machine: Some("vm-2".into()),
                ..request("Second pass")
            })
            .unwrap();
        assert!(
            answer.starts_with("outcome: done.") && answer.contains("ws_4"),
            "{answer}"
        );
        let run = &app.runs()[0];
        assert_eq!(run.1.as_deref(), Some("machine:vm-2"));
        // Keyed: a retry after a slow answer joins this run, never a second workspace.
        assert_eq!(
            run.3.as_deref(),
            Some("optchat-cloud-workspace-machine:vm-2-second-pass-0")
        );
    }

    /// Only a run the app did not answer keeps its key for the retry (which
    /// joins it); a refused or answered run leaves the next call a fresh
    /// run, so a stale failure or a closed workspace is never replayed.
    #[test]
    fn a_retry_joins_only_a_run_with_no_answer() {
        let app = FakeApp::new(vec![
            (
                "newCloudWorkspace",
                Err(RunError::NoAnswer("timed out".into())),
            ),
            (
                "newCloudWorkspace",
                Err(RunError::Refused("not connected".into())),
            ),
            ("newCloudWorkspace", Ok(json!({"workspace_id": "ws_1"}))),
            ("newCloudWorkspace", Ok(json!({"workspace_id": "ws_2"}))),
        ]);
        let tool = CloudWorkspaces::new(app.clone());
        let call = || {
            tool.call(&Request {
                machine: Some("machine:vm-5".into()),
                ..request("Review")
            })
        };
        let error = call().unwrap_err();
        assert!(error.contains("may still open"), "{error}");
        assert!(call().unwrap_err().contains("not connected"));
        assert!(call().unwrap().contains("ws_1"));
        assert!(call().unwrap().contains("ws_2"));
        let keys: Vec<String> = app.runs().into_iter().filter_map(|r| r.3).collect();
        let base = "optchat-cloud-workspace-machine:vm-5-review";
        assert_eq!(
            keys,
            [0, 0, 1, 2].map(|n| format!("{base}-{n}")),
            "the retry of the unanswered run joins it; the others move on"
        );
        // A key past the app's 200 characters is left out, not refused.
        let long = FakeApp::new(vec![(
            "newCloudWorkspace",
            Ok(json!({"workspace_id": "ws_3"})),
        )]);
        CloudWorkspaces::new(long.clone())
            .call(&Request {
                machine: Some(format!("machine:{}", "v".repeat(190))),
                ..request("Review")
            })
            .unwrap();
        assert_eq!(long.runs()[0].3, None);
    }

    /// The app's own list of creates on their way decides: a create of the
    /// name answers noop, a failed one says why, and none lets a create go
    /// even when this host asked for the name before.
    #[test]
    fn the_apps_creates_on_their_way_decide() {
        let listed = |creating: Value| {
            Ok(
                json!({"loaded": true, "machines": [], "creating": creating, "account": {"signed_in": true}}),
            )
        };
        let app = FakeApp::new(vec![(
            "cloudListMachines",
            listed(json!([{"creation_id": "c1", "name": "fix-login-bug", "status": "creating"}])),
        )]);
        let answer = CloudWorkspaces::new(app.clone())
            .call(&request("Fix login bug"))
            .unwrap();
        assert!(
            answer.starts_with("outcome: noop.") && answer.contains("still being made"),
            "{answer}"
        );

        let app = FakeApp::new(vec![(
            "cloudListMachines",
            listed(
                json!([{"creation_id": "c1", "name": "fix-login-bug", "status": "failed", "reason": "quota"}]),
            ),
        )]);
        let error = CloudWorkspaces::new(app.clone())
            .call(&request("Fix login bug"))
            .unwrap_err();
        assert!(
            error.contains("failed (quota)") && error.contains("Retry"),
            "{error}"
        );
        assert!(app.runs().iter().all(|r| r.0 != "newCloudMachine"));

        // This host held the name, but the app lists no such create: it failed and was dismissed.
        let app = FakeApp::new(vec![
            (
                "cloudListMachines",
                listed(json!([{"name": "other", "status": "creating"}])),
            ),
            (
                "newCloudMachine",
                Ok(json!({"machine_id": "vm-3", "target": "machine:vm-3"})),
            ),
        ]);
        let tool = CloudWorkspaces::new(app.clone());
        tool.creating
            .lock()
            .unwrap()
            .insert("fix-login-bug".into(), Instant::now());
        let answer = tool.call(&request("Fix login bug")).unwrap();
        assert!(
            answer.starts_with("outcome: done.") && answer.contains("machine:vm-3"),
            "{answer}"
        );
    }

    #[test]
    fn a_declined_create_says_so_and_bad_sizes_are_refused() {
        let app = FakeApp::new(vec![
            ("cloudListMachines", list(json!([]))),
            (
                "newCloudMachine",
                Err(RunError::Refused(
                    "The Cloud machine was not created.".into(),
                )),
            ),
        ]);
        let tool = CloudWorkspaces::new(app.clone());
        let error = tool.call(&request("task")).unwrap_err();
        assert!(error.contains("was not created"), "{error}");
        // A declined create is not "being made": the next call may ask again.
        assert!(tool.creating.lock().unwrap().is_empty());
        let error = tool
            .call(&Request {
                size: Some("huge".into()),
                ..request("task")
            })
            .unwrap_err();
        assert!(error.contains("size must be one of"), "{error}");
    }

    /// The app's own timeout answer is a run still going, never a refusal:
    /// its retry keeps the key and joins it.
    #[test]
    fn the_apps_timeout_is_no_answer() {
        let timeout = json!({"ok": false, "error": {"code": "timeout", "message": "action.run did not finish within 40000 ms"}});
        assert!(matches!(
            run_result(&timeout, ""),
            Err(RunError::NoAnswer(_))
        ));
        let refused =
            json!({"ok": false, "error": {"code": "unavailable", "message": "not connected"}});
        assert_eq!(
            run_result(&refused, ""),
            Err(RunError::Refused("not connected".into()))
        );
        let done = json!({"ok": true, "result": {"ran": true, "result": {"workspace_id": "ws_1"}}});
        assert_eq!(
            run_result(&done, "").unwrap(),
            json!({"workspace_id": "ws_1"})
        );
    }

    #[test]
    fn the_request_is_a_script_run_from_home() {
        let request = run_request(
            "newCloudWorkspace",
            Some("machine:vm-1"),
            json!({}),
            Some("k1"),
        );
        assert_eq!(request["params"]["idempotency_key"], "k1");
        assert_eq!(request["method"], "action.run");
        assert_eq!(request["params"]["origin"], "script");
        assert_eq!(request["params"]["target"], "machine:vm-1");
        assert_eq!(request["params"]["caller"], json!({"home_chat": true}));
        assert_eq!(request["params"]["wait"], true);
    }
}
