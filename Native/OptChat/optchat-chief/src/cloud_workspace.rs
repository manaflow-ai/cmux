//! The Chief's `cloud_workspace` tool (#25596): a cmux Cloud workspace for a
//! task, that is a Cloud machine named after the task and a workspace on it,
//! filed in the sidebar under the machine's group.
//!
//! The app makes both with its own actions over its control socket, the
//! paths the palette, the sidebar `+` and `cmux cloud` take:
//! `newCloudMachine {name, size}` creates the machine and opens its first
//! workspace when its daemon is up, and `newCloudWorkspace` with
//! `machine:<id>` opens another workspace on a machine that exists. The
//! runs are `script` origin, so the app asks the person before an agent's
//! create costs money, as it does for `cmux cloud new-machine`.
//!
//! A create can outlast the app's answer (it answers `pending` after 30 s).
//! The tool reads the machine list first and keeps the names it is still
//! creating, so a second call for the same task never makes a second
//! machine.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use serde_json::{Value, json};

/// The sizes `cmux cloud new-machine --size` takes.
pub const SIZES: [&str; 4] = ["small", "medium", "large", "xlarge"];

/// How long a name whose create answered `pending` stays "being made" when
/// the list does not show it yet: past it, a call creates again.
pub const CREATING_FOR: Duration = Duration::from_secs(15 * 60);

/// The longest a machine name is (the app takes 64).
const NAME_MAX: usize = 48;

/// One app action run, its `result` fields answered.
pub trait AppActions: Send + Sync {
    fn run(&self, action: &str, target: Option<&str>, args: Value) -> Result<Value, String>;
}

/// The app's control socket (`CMUX_SOCKET_PATH`).
pub struct ControlSocketActions {
    pub socket: PathBuf,
}

/// The longest one run may take: the app answers within its 40 s result
/// deadline, `pending` when the work goes on.
const RUN_TIMEOUT: Duration = Duration::from_secs(60);

impl AppActions for ControlSocketActions {
    fn run(&self, action: &str, target: Option<&str>, args: Value) -> Result<Value, String> {
        let request = run_request(action, target, args);
        let reply = crate::workspaces::control_call(&self.socket, &request, RUN_TIMEOUT)?;
        Ok(reply.get("result").cloned().unwrap_or(Value::Null))
    }
}

/// The `action.run` request: `script` origin, from the Chief's chat in Home
/// (`CMUX_CALLER_HOME_CHAT`, as the turn's own `cmux` runs say).
pub fn run_request(action: &str, target: Option<&str>, args: Value) -> Value {
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
    /// Names whose create answered `pending`, and when.
    creating: Mutex<HashMap<String, Instant>>,
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

    /// Another workspace on machine `machine`.
    fn on_machine(&self, machine: &str, title: &str) -> Result<String, String> {
        let machine = machine.trim();
        let target = if machine.starts_with("machine:") {
            machine.to_owned()
        } else {
            format!("machine:{machine}")
        };
        let result = self
            .app
            .run("newCloudWorkspace", Some(&target), json!({}))
            .map_err(|e| format!("cloud_workspace: {e}"))?;
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
            .run("cloudListMachines", None, json!({}))
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
        let existing = list["machines"].as_array().and_then(|machines| {
            machines.iter().find(|m| {
                m["title"]
                    .as_str()
                    .is_some_and(|t| t.eq_ignore_ascii_case(&name))
            })
        });
        if let Some(machine) = existing {
            self.creating.lock().expect("creating").remove(&name);
            let target = machine["target"].as_str().unwrap_or_default();
            let status = machine["status"].as_str().unwrap_or("unknown");
            return Ok(format!(
                "outcome: noop. Cloud machine {name} ({target}) already exists ({status}); its workspace is in the sidebar under it. For another workspace on it, call cloud_workspace with machine {target}."
            ));
        }
        let now = (self.now)();
        {
            let mut creating = self.creating.lock().expect("creating");
            creating.retain(|_, at| now.duration_since(*at) < CREATING_FOR);
            if let Some(at) = creating.get(&name) {
                let minutes = now.duration_since(*at).as_secs() / 60;
                return Ok(format!(
                    "outcome: noop. Cloud machine {name} is still being made (asked {minutes} min ago); it opens in the sidebar when it is up. Never ask for a second one."
                ));
            }
        }
        let mut args = json!({"name": name});
        if let Some(size) = &request.size {
            args["size"] = json!(size);
        }
        let result = self
            .app
            .run("newCloudMachine", None, args)
            .map_err(|e| format!("cloud_workspace: {e}"))?;
        if result["pending"] == true || result["machine_id"].as_str().is_none() {
            self.creating
                .lock()
                .expect("creating")
                .insert(name.clone(), now);
            return Ok(format!(
                "outcome: queued. Cloud machine {name} is being made; cmux may ask the person to confirm it first. Its workspace opens in the sidebar when it is up. Call cloud_workspace with the same title later to check; never ask for a second one."
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

    /// The app: answers by action, and records each run.
    struct FakeApp {
        answers: Mutex<HashMap<&'static str, Vec<Result<Value, String>>>>,
        runs: Mutex<Vec<(String, Option<String>, Value)>>,
    }

    impl FakeApp {
        fn new(answers: Vec<(&'static str, Result<Value, String>)>) -> Arc<FakeApp> {
            let mut map: HashMap<&'static str, Vec<Result<Value, String>>> = HashMap::new();
            for (action, answer) in answers {
                map.entry(action).or_default().push(answer);
            }
            Arc::new(FakeApp {
                answers: Mutex::new(map),
                runs: Mutex::new(Vec::new()),
            })
        }

        fn runs(&self) -> Vec<(String, Option<String>, Value)> {
            self.runs.lock().unwrap().clone()
        }
    }

    impl AppActions for FakeApp {
        fn run(&self, action: &str, target: Option<&str>, args: Value) -> Result<Value, String> {
            self.runs
                .lock()
                .unwrap()
                .push((action.to_owned(), target.map(str::to_owned), args));
            let mut answers = self.answers.lock().unwrap();
            let queue = answers.get_mut(action).expect("an answer for the action");
            if queue.len() > 1 {
                queue.remove(0)
            } else {
                queue[0].clone()
            }
        }
    }

    fn list(machines: Value) -> Result<Value, String> {
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
        assert_eq!(app.runs()[0].1.as_deref(), Some("machine:vm-2"));
    }

    #[test]
    fn a_declined_create_says_so_and_bad_sizes_are_refused() {
        let app = FakeApp::new(vec![
            ("cloudListMachines", list(json!([]))),
            (
                "newCloudMachine",
                Err("The Cloud machine was not created.".into()),
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

    #[test]
    fn the_request_is_a_script_run_from_home() {
        let request = run_request("newCloudWorkspace", Some("machine:vm-1"), json!({}));
        assert_eq!(request["method"], "action.run");
        assert_eq!(request["params"]["origin"], "script");
        assert_eq!(request["params"]["target"], "machine:vm-1");
        assert_eq!(request["params"]["caller"], json!({"home_chat": true}));
        assert_eq!(request["params"]["wait"], true);
    }
}
