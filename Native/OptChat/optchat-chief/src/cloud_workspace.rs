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
//! this host asked for, held for [`CREATING_FOR`], as does a create of this
//! host's still running or with no answer, which the list can lag.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use serde_json::{Value, json};

/// The sizes `cmux cloud new-machine --size` takes.
pub use chief_kernel::tools::SIZES;

/// How long a started create remains reserved when the app's list is still
/// catching up or the result was lost: past its own create retry window
/// (70 tries 15 s apart). Expiry moves the name's key on: the old create is
/// over, and its key would replay its old answer instead of making one.
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

/// A machine name reserved for a create, from before its run starts.
#[derive(Clone, Copy, Debug)]
struct Reservation {
    at: Instant,
    /// The attempt (key suffix) its run uses.
    attempt: u64,
    /// The [`State::seq`] it was made at: only a list read after it (at a
    /// later or equal `seq`) may say its create is over.
    seq: u64,
    /// The app answered its run done (a machine, not `pending`), at this
    /// `seq`: a list read after that names neither the create nor the
    /// machine is authoritative. A pending create keeps its name until the
    /// list names it made or failed, or it expires.
    done: Option<u64>,
}

/// The reservations and attempts, under one lock so that releasing a
/// reservation and moving its key on are one step.
#[derive(Default)]
struct State {
    /// Names reserved before a create begins, including pending, successful
    /// but not yet listed, or unanswered creates; held for CREATING_FOR.
    creating: HashMap<String, Reservation>,
    /// The attempt of each key base (a machine create, or a (machine, title)
    /// workspace run): its key's suffix. A workspace run's moves on after
    /// every run the app answered; a machine create's after a refusal or a
    /// finished create, so only a retry of a run still going reuses a key
    /// (and joins that run).
    attempts: HashMap<String, u64>,
    /// Counts reservations made and creates answered done: a call reads it
    /// before its list, so it knows which of them its list could have seen.
    seq: u64,
}

impl State {
    /// The next `seq`, for a reservation or a done answer.
    fn tick(&mut self) -> u64 {
        self.seq += 1;
        self.seq
    }

    /// A list read at `seen` says the create of `name` is over (made or
    /// failed): its reservation goes and its key moves on, unless the
    /// reservation is newer than the list, which then cannot speak for it
    /// (false).
    fn settle(&mut self, name: &str, base: &str, seen: u64) -> bool {
        let attempt = match self.creating.get(name).copied() {
            Some(r) if r.seq > seen => return false,
            Some(r) => {
                self.creating.remove(name);
                r.attempt
            }
            None => *self.attempts.entry(base.to_owned()).or_default(),
        };
        self.advance(base, attempt);
        true
    }

    /// Moves `base` on past `attempt`, unless another call already did.
    fn advance(&mut self, base: &str, attempt: u64) {
        let next = self.attempts.entry(base.to_owned()).or_default();
        if *next == attempt {
            *next += 1;
        }
    }

    /// Drops the reservation of `name` if it is still the one for `attempt`.
    fn release(&mut self, name: &str, attempt: u64) {
        if self
            .creating
            .get(name)
            .is_some_and(|r| r.attempt == attempt)
        {
            self.creating.remove(name);
        }
    }
}

/// A start no other Chief shares: microseconds since the epoch, moved past
/// this process's last one, then this process's id; digits only.
fn epoch() -> u128 {
    use std::sync::atomic::{AtomicU64, Ordering};
    static LAST: AtomicU64 = AtomicU64::new(0);
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_micros() as u64);
    let prev = LAST
        .fetch_update(Ordering::Relaxed, Ordering::Relaxed, |last| {
            Some(now.max(last + 1))
        })
        .unwrap_or_default();
    let micros = now.max(prev + 1);
    u128::from(micros) * 10_000_000_000 + u128::from(std::process::id())
}

/// The key base of a machine create of `name`.
fn machine_key_base(name: &str) -> String {
    format!("optchat-cloud-machine-{name}")
}

/// The tool, over the app's actions.
pub struct CloudWorkspaces {
    app: Arc<dyn AppActions>,
    state: Mutex<State>,
    /// This Chief's start ([`epoch`]), in every machine create's
    /// key: the app keeps finished runs' replies past a Chief restart, and
    /// the attempts restart at 0, so without it a create after a restart
    /// would replay the reply of an old one (a machine since deleted).
    epoch: u128,
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
            state: Mutex::new(State::default()),
            epoch: epoch(),
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
                .state
                .lock()
                .expect("state")
                .attempts
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
                .state
                .lock()
                .expect("state")
                .attempts
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
        // Read before the list: a reservation or answer counted after it
        // came after the list was read, which may not name that create yet.
        let seen = self.state.lock().expect("state").seq;
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
        // The idempotency key is stable through NoAnswer. It moves on only
        // once its create is over (refused, done, or listed as made or
        // failed); a retry after an ambiguous reply must join the same app
        // action, not provision twice. A create still on its way when Chief
        // restarts is in the app's `creating` list, which answers for it.
        let base_key = machine_key_base(&name);
        if let Some(machine) = existing {
            // A listed machine is a finished create: a later create of the
            // name (once this one is deleted or renamed) is a new action,
            // never a replay of this one.
            // A create newer than the list keeps its reservation and key.
            self.state
                .lock()
                .expect("state")
                .settle(&name, &base_key, seen);
            let target = machine["target"].as_str().unwrap_or_default();
            let status = machine["status"].as_str().unwrap_or("unknown");
            return Ok(format!(
                "outcome: noop. Cloud machine {name} ({target}) already exists ({status}); its workspace is in the sidebar under it. For another workspace on it, call cloud_workspace with machine {target}."
            ));
        }
        let now = (self.now)();
        // A name must be reserved BEFORE action.run, atomically with the
        // in-flight check and the attempt read. Otherwise two calls can both
        // see no machine and both create one, or a NoAnswer can lose an
        // accepted remote create.
        let attempt = {
            let mut state = self.state.lock().expect("state");
            // The app lists its creates still on their way: one of the name
            // decides. An app that does not: the names this host asked for.
            if let Some(creates) = list["creating"].as_array() {
                if let Some(create) = creates.iter().find(|c| named(c, "name")) {
                    // A failed create is over: a later one is a new action.
                    // A list older than this host's create of the name speaks
                    // for an earlier one: the newer create is still being made.
                    if create["status"] == "failed" && state.settle(&name, &base_key, seen) {
                        let reason = create["reason"].as_str().unwrap_or("no reason given");
                        return Err(format!(
                            "cloud_workspace: the create of Cloud machine {name} failed ({reason}); it is in the sidebar, where the person can Retry or dismiss it. Tell them; do not make another."
                        ));
                    }
                    return Ok(format!(
                        "outcome: noop. Cloud machine {name} is still being made; its workspace opens in the sidebar when it is up. Never ask for a second one."
                    ));
                }
                // Named nowhere: a create the app answered done before this
                // list was read is over (its machine was deleted). A create
                // pending, with no answer, or answered after the list was
                // read keeps its name, as the list can lag it.
                if let Some(r) = state.creating.get(&name).copied()
                    && r.done.is_some_and(|n| n <= seen)
                {
                    state.release(&name, r.attempt);
                    state.advance(&base_key, r.attempt);
                }
            }
            // Expire only after the list had its say: a done create the list
            // no longer names moves its key on above, whatever its age.
            // An expired create is over too: its key moves on, or every retry
            // would replay its old answer and never make the machine.
            let expired: Vec<(String, u64)> = state
                .creating
                .iter()
                .filter(|(_, r)| now.duration_since(r.at) >= CREATING_FOR)
                .map(|(name, r)| (name.clone(), r.attempt))
                .collect();
            for (expired, attempt) in expired {
                state.release(&expired, attempt);
                state.advance(&machine_key_base(&expired), attempt);
            }
            if let Some(r) = state.creating.get(&name) {
                let minutes = now.duration_since(r.at).as_secs() / 60;
                return Ok(format!(
                    "outcome: noop. Cloud machine {name} is still being made (asked {minutes} min ago); it opens in the sidebar when it is up. Never ask for a second one."
                ));
            }
            let attempt = *state.attempts.entry(base_key.clone()).or_default();
            let seq = state.tick();
            state.creating.insert(
                name.clone(),
                Reservation {
                    at: now,
                    attempt,
                    seq,
                    done: None,
                },
            );
            attempt
        };

        let mut args = json!({"name": name});
        if let Some(size) = &request.size {
            args["size"] = json!(size);
        }
        let key = format!("{base_key}-{attempt}-c{}", self.epoch);
        let answer = self.app.run("newCloudMachine", None, args, Some(&key));
        {
            // Releasing the name and moving the key on happen in one step,
            // and only for this call's attempt: a retry that replays an old
            // refusal never moves on the key of a newer create.
            let mut state = self.state.lock().expect("state");
            match &answer {
                Err(RunError::Refused(_)) => {
                    state.release(&name, attempt);
                    state.advance(&base_key, attempt);
                }
                Err(RunError::NoAnswer(_)) => {}
                Ok(result) => {
                    if result["pending"] != true && result["machine_id"].as_str().is_some() {
                        let seq = state.tick();
                        if let Some(r) = state.creating.get_mut(&name)
                            && r.attempt == attempt
                        {
                            r.done = Some(seq);
                        }
                        state.advance(&base_key, attempt);
                    }
                }
            }
        }
        let result = answer.map_err(|e| match e {
            RunError::NoAnswer(_) => format!(
                "cloud_workspace: {e}. The create may still finish; retrying the same title checks its status and rejoins the original action. Do not request a second machine."
            ),
            RunError::Refused(_) => format!("cloud_workspace: {e}"),
        })?;
        if result["pending"] == true || result["machine_id"].as_str().is_none() {
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

    /// A machine create's key without this Chief's start (`-c<ms>`).
    fn without_epoch(key: Option<String>) -> Option<String> {
        key.map(|k| match k.rsplit_once("-c") {
            Some((key, epoch)) if epoch.bytes().all(|b| b.is_ascii_digit()) => key.to_owned(),
            _ => k,
        })
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
        assert_eq!(
            without_epoch(runs[1].3.clone()).as_deref(),
            Some("optchat-cloud-machine-fix-login-bug-0")
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
        // Past the window the create is over: a call makes one under a new
        // key, never replaying the old create's `pending`.
        *at.lock().unwrap() = start + CREATING_FOR;
        tool.call(&request("fix login bug")).unwrap();
        assert_eq!(creates(&app), 2);
        let keys: Vec<_> = app
            .runs()
            .into_iter()
            .filter(|r| r.0 == "newCloudMachine")
            .map(|r| without_epoch(r.3))
            .collect();
        assert_eq!(
            keys,
            vec![
                Some("optchat-cloud-machine-fix-login-bug-0".into()),
                Some("optchat-cloud-machine-fix-login-bug-1".into())
            ]
        );
    }

    #[test]
    fn an_unanswered_machine_create_is_reserved_and_uses_one_key() {
        let app = FakeApp::new(vec![
            ("cloudListMachines", list(json!([]))),
            (
                "newCloudMachine",
                Err(RunError::NoAnswer("socket closed".into())),
            ),
        ]);
        let start = Instant::now();
        let at = Arc::new(Mutex::new(start));
        let clock = at.clone();
        let tool =
            CloudWorkspaces::with_clock(app.clone(), Box::new(move || *clock.lock().unwrap()));
        let first = tool.call(&request("Fix login bug")).unwrap_err();
        assert!(first.contains("may still finish"), "{first}");
        *at.lock().unwrap() = start + Duration::from_secs(40);
        let second = tool.call(&request("Fix login bug")).unwrap();
        assert!(second.starts_with("outcome: noop."), "{second}");
        let runs = app.runs();
        assert_eq!(runs.iter().filter(|r| r.0 == "newCloudMachine").count(), 1);
        assert_eq!(
            without_epoch(runs[1].3.clone()).as_deref(),
            Some("optchat-cloud-machine-fix-login-bug-0")
        );

        // Past the bounded reservation the create is over (its retry window
        // is shorter): the next one goes under a new key, so a kept old
        // answer is never replayed in its place.
        *at.lock().unwrap() = start + CREATING_FOR;
        assert!(
            tool.call(&request("Fix login bug"))
                .unwrap_err()
                .contains("may still finish")
        );
        let keys: Vec<_> = app
            .runs()
            .into_iter()
            .filter(|r| r.0 == "newCloudMachine")
            .map(|r| without_epoch(r.3))
            .collect();
        assert_eq!(
            keys,
            vec![
                Some("optchat-cloud-machine-fix-login-bug-0".into()),
                Some("optchat-cloud-machine-fix-login-bug-1".into())
            ]
        );
    }

    #[test]
    fn concurrent_calls_for_one_title_send_only_one_create() {
        let app = FakeApp::new(vec![
            ("cloudListMachines", list(json!([]))),
            (
                "newCloudMachine",
                Ok(json!({"machine_id": "vm-1", "target": "machine:vm-1"})),
            ),
        ]);
        let tool = Arc::new(CloudWorkspaces::new(app.clone()));
        let barrier = Arc::new(std::sync::Barrier::new(8));
        let handles: Vec<_> = (0..8)
            .map(|_| {
                let tool = Arc::clone(&tool);
                let barrier = Arc::clone(&barrier);
                std::thread::spawn(move || {
                    barrier.wait();
                    tool.call(&request("Fix login bug"))
                })
            })
            .collect();
        for handle in handles {
            assert!(handle.join().unwrap().is_ok());
        }
        assert_eq!(
            app.runs()
                .iter()
                .filter(|r| r.0 == "newCloudMachine")
                .count(),
            1
        );
    }

    #[test]
    fn a_refused_create_releases_the_name_and_advances_its_key() {
        let app = FakeApp::new(vec![
            ("cloudListMachines", list(json!([]))),
            ("newCloudMachine", Err(RunError::Refused("plan cap".into()))),
            ("newCloudMachine", Ok(json!({"machine_id": "vm-2"}))),
        ]);
        let tool = CloudWorkspaces::new(app.clone());
        assert!(
            tool.call(&request("Fix login bug"))
                .unwrap_err()
                .contains("plan cap")
        );
        assert!(tool.state.lock().unwrap().creating.is_empty());
        assert!(
            tool.call(&request("Fix login bug"))
                .unwrap()
                .starts_with("outcome: done.")
        );
        let keys: Vec<_> = app
            .runs()
            .into_iter()
            .filter(|r| r.0 == "newCloudMachine")
            .map(|r| without_epoch(r.3))
            .collect();
        assert_eq!(
            keys,
            vec![
                Some("optchat-cloud-machine-fix-login-bug-0".into()),
                Some("optchat-cloud-machine-fix-login-bug-1".into())
            ]
        );
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

        // This host's create of the name was answered done, but the app lists no
        // such create: it failed and was dismissed, so a create goes, as a
        // new action.
        let reserved = |answered: bool| {
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
            tool.state.lock().unwrap().creating.insert(
                "fix-login-bug".into(),
                Reservation {
                    at: Instant::now(),
                    attempt: 0,
                    seq: 0,
                    done: answered.then_some(0),
                },
            );
            (app, tool)
        };
        let (app, tool) = reserved(true);
        let answer = tool.call(&request("Fix login bug")).unwrap();
        assert!(
            answer.starts_with("outcome: done.") && answer.contains("machine:vm-3"),
            "{answer}"
        );
        assert_eq!(
            without_epoch(app.runs()[1].3.clone()).as_deref(),
            Some("optchat-cloud-machine-fix-login-bug-1")
        );

        // A create still running or with no answer keeps its name: the list
        // can lag an accepted request.
        let (app, tool) = reserved(false);
        let answer = tool.call(&request("Fix login bug")).unwrap();
        assert!(answer.starts_with("outcome: noop."), "{answer}");
        assert!(app.runs().iter().all(|r| r.0 != "newCloudMachine"));
    }

    /// A refusal releases the name and moves the key on only for the attempt
    /// it answered: a retry that replays an old refusal after a newer create
    /// started leaves that create's reservation and key alone.
    #[test]
    fn a_stale_refusal_never_moves_a_newer_create_on() {
        let mut state = State::default();
        let base = "optchat-cloud-machine-fix-login-bug";
        state.attempts.insert(base.into(), 1);
        state.creating.insert(
            "fix-login-bug".into(),
            Reservation {
                at: Instant::now(),
                attempt: 1,
                seq: 0,
                done: None,
            },
        );
        state.release("fix-login-bug", 0);
        state.advance(base, 0);
        assert_eq!(state.attempts[base], 1);
        assert_eq!(state.creating["fix-login-bug"].attempt, 1);
        state.release("fix-login-bug", 1);
        state.advance(base, 1);
        assert_eq!(state.attempts[base], 2);
        assert!(state.creating.is_empty());
    }

    /// A pending create the list stopped naming (it failed and was dismissed)
    /// moves its key on even when the next call comes past CREATING_FOR:
    /// the old key would replay `pending` and start nothing.
    #[test]
    fn an_expired_answered_create_still_moves_its_key_on() {
        let listed = |creating: Value| {
            Ok(
                json!({"loaded": true, "machines": [], "creating": creating, "account": {"signed_in": true}}),
            )
        };
        let app = FakeApp::new(vec![
            ("cloudListMachines", listed(json!([]))),
            (
                "newCloudMachine",
                Ok(json!({"pending": true, "status": "creating"})),
            ),
            (
                "newCloudMachine",
                Ok(json!({"machine_id": "vm-2", "target": "machine:vm-2"})),
            ),
        ]);
        let start = Instant::now();
        let at = Arc::new(Mutex::new(start));
        let clock = at.clone();
        let tool =
            CloudWorkspaces::with_clock(app.clone(), Box::new(move || *clock.lock().unwrap()));
        assert!(
            tool.call(&request("Fix login bug"))
                .unwrap()
                .starts_with("outcome: queued.")
        );
        *at.lock().unwrap() = start + CREATING_FOR + Duration::from_secs(60);
        assert!(
            tool.call(&request("Fix login bug"))
                .unwrap()
                .contains("vm-2")
        );
        let keys: Vec<_> = app
            .runs()
            .into_iter()
            .filter(|r| r.0 == "newCloudMachine")
            .map(|r| without_epoch(r.3))
            .collect();
        assert_eq!(
            keys,
            vec![
                Some("optchat-cloud-machine-fix-login-bug-0".into()),
                Some("optchat-cloud-machine-fix-login-bug-1".into())
            ]
        );
    }

    /// Holds the first list run, read but unanswered, until the test lets
    /// it answer: a list snapshot taken before what other calls do next.
    struct HeldList {
        app: Arc<FakeApp>,
        held: Mutex<Option<(std::sync::mpsc::Sender<()>, std::sync::mpsc::Receiver<()>)>>,
    }

    impl AppActions for HeldList {
        fn run(
            &self,
            action: &str,
            target: Option<&str>,
            args: Value,
            key: Option<&str>,
        ) -> Result<Value, RunError> {
            let held = if action == "cloudListMachines" {
                self.held.lock().unwrap().take()
            } else {
                None
            };
            let answer = self.app.run(action, target, args, key);
            if let Some((entered, release)) = held {
                entered.send(()).unwrap();
                release.recv().unwrap();
            }
            answer
        }
    }

    /// Runs one call whose list is read now and answered only after `then`.
    fn with_a_stale_list(app: &Arc<FakeApp>, then: impl FnOnce(&CloudWorkspaces)) -> String {
        let (entered_tx, entered) = std::sync::mpsc::channel();
        let (release, release_rx) = std::sync::mpsc::channel();
        let tool = Arc::new(CloudWorkspaces::new(Arc::new(HeldList {
            app: app.clone(),
            held: Mutex::new(Some((entered_tx, release_rx))),
        })));
        let stale = {
            let tool = Arc::clone(&tool);
            std::thread::spawn(move || tool.call(&request("Fix login bug")))
        };
        entered.recv().unwrap();
        then(&tool);
        release.send(()).unwrap();
        let answer = stale.join().unwrap().unwrap();
        then_check(&tool, app);
        answer
    }

    /// After the stale call: one create only, and its reservation stands.
    fn then_check(tool: &CloudWorkspaces, app: &FakeApp) {
        assert_eq!(
            app.runs()
                .iter()
                .filter(|r| r.0 == "newCloudMachine")
                .count(),
            1
        );
        let state = tool.state.lock().unwrap();
        assert_eq!(state.creating["fix-login-bug"].attempt, 0);
        assert_eq!(state.attempts["optchat-cloud-machine-fix-login-bug"], 0);
    }

    fn listed(machines: Value) -> Result<Value, RunError> {
        Ok(
            json!({"loaded": true, "machines": machines, "creating": [], "account": {"signed_in": true}}),
        )
    }

    /// A list read before another call's create started is stale: it not
    /// naming that create never releases it, so no second create goes.
    #[test]
    fn a_list_read_before_a_create_never_releases_it() {
        let app = FakeApp::new(vec![
            ("cloudListMachines", listed(json!([]))),
            (
                "newCloudMachine",
                Ok(json!({"pending": true, "status": "creating"})),
            ),
        ]);
        let answer = with_a_stale_list(&app, |tool| {
            let first = tool.call(&request("Fix login bug")).unwrap();
            assert!(first.starts_with("outcome: queued."), "{first}");
        });
        assert!(answer.starts_with("outcome: noop."), "{answer}");
    }

    /// A pending create keeps its name even against a list read after its
    /// answer that names nothing (the list can lag the create): only the
    /// list naming it made or failed, or its expiry, lets another go.
    #[test]
    fn a_pending_create_outlasts_a_list_that_lags_it() {
        let app = FakeApp::new(vec![
            ("cloudListMachines", listed(json!([]))),
            (
                "newCloudMachine",
                Ok(json!({"pending": true, "status": "creating"})),
            ),
        ]);
        let tool = CloudWorkspaces::new(app.clone());
        assert!(
            tool.call(&request("Fix login bug"))
                .unwrap()
                .starts_with("outcome: queued.")
        );
        let again = tool.call(&request("Fix login bug")).unwrap();
        assert!(again.starts_with("outcome: noop."), "{again}");
        then_check(&tool, &app);
    }

    /// A list read before a create started that shows a machine of the name
    /// (since deleted) never drops that newer create's reservation or moves
    /// its key on: a later call is answered by the reservation.
    #[test]
    fn a_stale_listed_machine_never_drops_a_newer_reservation() {
        let app = FakeApp::new(vec![
            (
                "cloudListMachines",
                listed(json!([{"title": "fix-login-bug", "target": "machine:vm-1"}])),
            ),
            ("cloudListMachines", listed(json!([]))),
            (
                "newCloudMachine",
                Ok(json!({"pending": true, "status": "creating"})),
            ),
        ]);
        let answer = with_a_stale_list(&app, |tool| {
            let first = tool.call(&request("Fix login bug")).unwrap();
            assert!(first.starts_with("outcome: queued."), "{first}");
        });
        assert!(answer.contains("already exists"), "{answer}");
    }

    /// A failed row in a list read before this host's newer create of the
    /// name speaks for an earlier create: the newer one is still being made.
    #[test]
    fn a_stale_failed_row_never_reports_a_newer_create_failed() {
        let app = FakeApp::new(vec![
            (
                "cloudListMachines",
                Ok(
                    json!({"loaded": true, "machines": [], "creating": [{"name": "fix-login-bug", "status": "failed", "reason": "quota"}], "account": {"signed_in": true}}),
                ),
            ),
            ("cloudListMachines", listed(json!([]))),
            (
                "newCloudMachine",
                Ok(json!({"pending": true, "status": "creating"})),
            ),
        ]);
        let answer = with_a_stale_list(&app, |tool| {
            let first = tool.call(&request("Fix login bug")).unwrap();
            assert!(first.starts_with("outcome: queued."), "{first}");
        });
        assert!(
            answer.starts_with("outcome: noop.") && answer.contains("still being made"),
            "{answer}"
        );
    }

    /// Two Chiefs never share a start, however close: a create of one never
    /// replays the other's under the same key.
    #[test]
    fn every_chief_start_is_its_own() {
        let starts: Vec<u128> = (0..1000).map(|_| epoch()).collect();
        assert!(starts.windows(2).all(|w| w[0] < w[1]));
        assert!(
            starts
                .iter()
                .all(|e| e % 10_000_000_000 == u128::from(std::process::id()))
        );
    }

    /// A done create whose machine a list read after the answer no longer
    /// names (it was deleted) is over: the next create goes, under a new key.
    #[test]
    fn a_done_create_a_later_list_no_longer_names_is_over() {
        let app = FakeApp::new(vec![
            ("cloudListMachines", listed(json!([]))),
            (
                "newCloudMachine",
                Ok(json!({"machine_id": "vm-1", "target": "machine:vm-1"})),
            ),
        ]);
        let tool = CloudWorkspaces::new(app.clone());
        tool.call(&request("Fix login bug")).unwrap();
        tool.call(&request("Fix login bug")).unwrap();
        let keys: Vec<_> = app
            .runs()
            .into_iter()
            .filter(|r| r.0 == "newCloudMachine")
            .map(|r| without_epoch(r.3))
            .collect();
        assert_eq!(
            keys,
            vec![
                Some("optchat-cloud-machine-fix-login-bug-0".into()),
                Some("optchat-cloud-machine-fix-login-bug-1".into())
            ]
        );
    }

    /// An expired reservation moves its key on, pending and unanswered alike,
    /// on an app with no `creating` list: the old key would replay the old
    /// answer on every retry and never make the machine.
    #[test]
    fn an_expired_reservation_moves_its_key_on() {
        for first in [
            Ok(json!({"pending": true, "status": "creating"})),
            Err(RunError::NoAnswer("socket closed".into())),
        ] {
            let app = FakeApp::new(vec![
                ("cloudListMachines", list(json!([]))),
                ("newCloudMachine", first),
                (
                    "newCloudMachine",
                    Ok(json!({"machine_id": "vm-2", "target": "machine:vm-2"})),
                ),
            ]);
            let start = Instant::now();
            let at = Arc::new(Mutex::new(start));
            let clock = at.clone();
            let tool =
                CloudWorkspaces::with_clock(app.clone(), Box::new(move || *clock.lock().unwrap()));
            let _ = tool.call(&request("Fix login bug"));
            *at.lock().unwrap() = start + CREATING_FOR;
            assert!(
                tool.call(&request("Fix login bug"))
                    .unwrap()
                    .contains("vm-2")
            );
            let keys: Vec<_> = app
                .runs()
                .into_iter()
                .filter(|r| r.0 == "newCloudMachine")
                .map(|r| without_epoch(r.3))
                .collect();
            assert_eq!(
                keys,
                vec![
                    Some("optchat-cloud-machine-fix-login-bug-0".into()),
                    Some("optchat-cloud-machine-fix-login-bug-1".into())
                ]
            );
        }
    }

    /// The app keeps finished replies past a Chief restart, while the
    /// attempts start again at 0: each Chief's creates carry its start, so a
    /// restarted Chief never replays an old create's reply.
    #[test]
    fn a_restarted_chief_never_replays_an_old_create() {
        let app = FakeApp::new(vec![
            ("cloudListMachines", list(json!([]))),
            (
                "newCloudMachine",
                Ok(json!({"machine_id": "vm-1", "target": "machine:vm-1"})),
            ),
        ]);
        let mut before = CloudWorkspaces::new(app.clone());
        before.epoch = 1;
        before.call(&request("Fix login bug")).unwrap();
        let mut after = CloudWorkspaces::new(app.clone());
        after.epoch = 2;
        after.call(&request("Fix login bug")).unwrap();
        let keys: Vec<_> = app
            .runs()
            .into_iter()
            .filter(|r| r.0 == "newCloudMachine")
            .filter_map(|r| r.3)
            .collect();
        assert_eq!(
            keys,
            vec![
                "optchat-cloud-machine-fix-login-bug-0-c1".to_owned(),
                "optchat-cloud-machine-fix-login-bug-0-c2".to_owned()
            ]
        );
    }

    /// A finished create never lends its key to a later one of the same name
    /// (after the machine is deleted or renamed): the app would replay the
    /// old success.
    #[test]
    fn a_finished_create_gives_the_next_one_a_fresh_key() {
        let listed = |machines: Value| {
            Ok(
                json!({"loaded": true, "machines": machines, "creating": [], "account": {"signed_in": true}}),
            )
        };
        let app = FakeApp::new(vec![
            ("cloudListMachines", listed(json!([]))),
            (
                "cloudListMachines",
                listed(json!([{"title": "fix-login-bug", "target": "machine:vm-1"}])),
            ),
            ("cloudListMachines", listed(json!([]))),
            (
                "newCloudMachine",
                Ok(json!({"machine_id": "vm-1", "target": "machine:vm-1"})),
            ),
            (
                "newCloudMachine",
                Ok(json!({"machine_id": "vm-2", "target": "machine:vm-2"})),
            ),
        ]);
        let tool = CloudWorkspaces::new(app.clone());
        assert!(
            tool.call(&request("Fix login bug"))
                .unwrap()
                .contains("vm-1")
        );
        assert!(
            tool.call(&request("Fix login bug"))
                .unwrap()
                .contains("already exists")
        );
        // The machine was deleted: a new one, under a new key.
        assert!(
            tool.call(&request("Fix login bug"))
                .unwrap()
                .contains("vm-2")
        );
        let keys: Vec<_> = app
            .runs()
            .into_iter()
            .filter(|r| r.0 == "newCloudMachine")
            .map(|r| without_epoch(r.3))
            .collect();
        assert_eq!(
            keys,
            vec![
                Some("optchat-cloud-machine-fix-login-bug-0".into()),
                Some("optchat-cloud-machine-fix-login-bug-1".into())
            ]
        );

        // Without a listing in between (an app with no `creating`), a done
        // answer alone moves the key on once its reservation lapses.
        let start = Instant::now();
        let at = Arc::new(Mutex::new(start));
        let clock = at.clone();
        let app = FakeApp::new(vec![
            ("cloudListMachines", list(json!([]))),
            (
                "newCloudMachine",
                Ok(json!({"machine_id": "vm-1", "target": "machine:vm-1"})),
            ),
        ]);
        let tool =
            CloudWorkspaces::with_clock(app.clone(), Box::new(move || *clock.lock().unwrap()));
        tool.call(&request("Fix login bug")).unwrap();
        *at.lock().unwrap() = start + CREATING_FOR;
        tool.call(&request("Fix login bug")).unwrap();
        let keys: Vec<_> = app
            .runs()
            .into_iter()
            .filter(|r| r.0 == "newCloudMachine")
            .map(|r| without_epoch(r.3))
            .collect();
        assert_eq!(
            keys,
            vec![
                Some("optchat-cloud-machine-fix-login-bug-0".into()),
                Some("optchat-cloud-machine-fix-login-bug-1".into())
            ]
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
        assert!(tool.state.lock().unwrap().creating.is_empty());
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
