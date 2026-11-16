use std::sync::Mutex;

use super::*;

const TOKEN: &str = "cmj_door_a_secret_token_0123456789abcdef";
const ORIGIN: &str = "https://hub.example.test";

/// ssh that answers each call from a script and records what it was asked.
struct FakeSsh {
    answers: Mutex<Vec<Ran>>,
    /// Lines the join "prints" while it runs, fed to the line callback.
    lines: Vec<&'static str>,
    seen: Mutex<Vec<(Vec<String>, Option<String>)>>,
}

impl FakeSsh {
    fn new(answers: Vec<Ran>) -> Self {
        Self { answers: Mutex::new(answers), lines: Vec::new(), seen: Mutex::new(Vec::new()) }
    }

    fn seen(&self) -> Vec<(Vec<String>, Option<String>)> {
        self.seen.lock().unwrap().clone()
    }
}

impl Ssh for FakeSsh {
    fn run<'a>(
        &'a self,
        plan: SshPlan,
        line: &'a mut (dyn FnMut(&str) + Send),
    ) -> BoxFut<'a, std::io::Result<Ran>> {
        Box::pin(async move {
            let stdin = plan.stdin.as_ref().map(|s| s.as_str().to_owned());
            let install = stdin.is_some();
            self.seen.lock().unwrap().push((plan.argv.clone(), stdin));
            if install {
                for text in &self.lines {
                    line(text);
                }
            }
            let mut answers = self.answers.lock().unwrap();
            Ok(if answers.is_empty() { ok("") } else { answers.remove(0) })
        })
    }
}

struct FakeHub {
    mint: Result<(), (u16, &'static str)>,
    unreachable: bool,
    reports: bool,
    mints: Mutex<usize>,
}

impl FakeHub {
    fn up() -> Self {
        Self { mint: Ok(()), unreachable: false, reports: true, mints: Mutex::new(0) }
    }
}

impl Hub for FakeHub {
    fn origin(&self) -> &str {
        ORIGIN
    }

    fn mint<'a>(&'a self, _label: Option<&'a str>) -> BoxFut<'a, Result<Minted, HubError>> {
        Box::pin(async move {
            *self.mints.lock().unwrap() += 1;
            if self.unreachable {
                return Err(HubError::Unreachable("connection refused".into()));
            }
            match self.mint {
                Ok(()) => Ok(Minted {
                    token: Zeroizing::new(TOKEN.to_owned()),
                    join_token_id: "join_01".into(),
                }),
                Err((status, code)) => Err(HubError::Status { status, code: code.into() }),
            }
        })
    }

    fn machines(&self) -> BoxFut<'_, Result<Vec<Row>, HubError>> {
        Box::pin(async move {
            Ok(if self.reports {
                vec![Row {
                    machine_id: "machine_01".into(),
                    name: "gcp-3".into(),
                    join_token_id: Some("join_01".into()),
                    last_heartbeat_ms: Some(now_ms()),
                    revoked: false,
                }]
            } else {
                Vec::new()
            })
        })
    }
}

fn ok(stdout: &str) -> Ran {
    Ran { code: 0, stdout: stdout.into(), stderr: Vec::new() }
}

fn failed(code: i32, stderr: &[&str]) -> Ran {
    Ran { code, stdout: String::new(), stderr: stderr.iter().map(|s| (*s).to_owned()).collect() }
}

fn request(host: &str) -> Request {
    Request { host: host.into(), name: None, hub: None }
}

async fn run(host: &str, ssh: &FakeSsh, hub: &FakeHub) -> (Outcome, Vec<Progress>) {
    let mut events = Vec::new();
    let outcome = join(&request(host), ssh, hub, &mut |p| events.push(p)).await;
    (outcome, events)
}

fn failure(outcome: &Outcome) -> &Failure {
    outcome.failure.as_ref().expect("a failure")
}

#[tokio::test]
async fn the_join_token_goes_on_stdin_and_never_in_an_argument_list() {
    let mut ssh = FakeSsh::new(vec![ok("Linux x86_64\n"), ok("")]);
    ssh.lines = vec!["cmux join: installing acpmux 2026.11.16", "cmux join: joined as gcp-3"];
    let hub = FakeHub::up();
    let (outcome, events) = run("gcp-3", &ssh, &hub).await;
    assert!(outcome.ok, "{outcome:?}");
    assert_eq!(outcome.machine.as_ref().map(|m| m.machine_id.as_str()), Some("machine_01"));
    assert_eq!(outcome.platform.as_deref(), Some("Linux x86_64"));

    let seen = ssh.seen();
    assert_eq!(seen.len(), 2, "reach, then install");
    for (argv, _) in &seen {
        for word in argv {
            assert!(!word.contains(TOKEN), "the token is in ssh's argv: {argv:?}");
            assert!(!word.contains("cmj_"), "a token is in ssh's argv: {argv:?}");
        }
        assert!(argv.iter().any(|w| w == "BatchMode=yes"), "ssh may never prompt: {argv:?}");
        assert_eq!(argv.iter().rev().nth(1).map(String::as_str), Some("gcp-3"));
        assert_eq!(argv.iter().rev().nth(2).map(String::as_str), Some("--"));
    }
    assert_eq!(seen[0].1, None, "the probe sends no token");
    assert_eq!(seen[1].1.as_deref(), Some(format!("{TOKEN}\n").as_str()));
    let remote = seen[1].0.last().unwrap();
    assert!(remote.contains("IFS= read -r t"), "{remote}");
    assert!(remote.contains("CMUX_JOIN=\"$t\""), "{remote}");
    assert!(remote.contains(&format!("{ORIGIN}/v1/machines/join.sh")), "{remote}");

    let steps: Vec<(Step, &str)> = events.iter().map(|p| (p.step, p.state)).collect();
    assert_eq!(steps.first(), Some(&(Step::Reach, "running")));
    assert_eq!(steps.last(), Some(&(Step::Connect, "ok")));
    assert!(
        events
            .iter()
            .any(|p| p.step == Step::Install && p.detail == "installing acpmux 2026.11.16"),
        "the script's own lines are the install progress: {events:?}"
    );
    // Neither the answer nor a progress event carries the token.
    let printed = format!("{} {:?}", outcome.to_value(), events);
    assert!(!printed.contains(TOKEN), "{printed}");
}

#[test]
fn a_plan_never_prints_its_token() {
    let plan = join_plan("ssh", ORIGIN, "gcp-3", Some("gcp-3"), TOKEN);
    let shown = format!("{plan:?}");
    assert!(!shown.contains(TOKEN), "{shown}");
    assert!(plan.argv.iter().all(|w| !w.contains(TOKEN)));
    assert!(plan.argv.last().unwrap().contains(" CMUX_JOIN_NAME=gcp-3 sh"));
}

/// Every failure says what happened and its next step, each in one line.
fn one_line(failure: &Failure) {
    assert!(!failure.message.contains('\n'), "{failure:?}");
    assert!(!failure.next.is_empty() && !failure.next.contains('\n'), "{failure:?}");
}

#[tokio::test]
async fn ssh_that_refuses_the_key_says_to_copy_one_and_mints_nothing() {
    let ssh = FakeSsh::new(vec![failed(255, &["cmux@gcp-3: Permission denied (publickey)."])]);
    let hub = FakeHub::up();
    let (outcome, _) = run("gcp-3", &ssh, &hub).await;
    let f = failure(&outcome);
    assert_eq!(f.kind, Kind::NeedsKey);
    assert!(f.next.contains("ssh-copy-id gcp-3"), "{f:?}");
    one_line(f);
    assert_eq!(*hub.mints.lock().unwrap(), 0, "no join line for a host ssh cannot enter");
}

#[tokio::test]
async fn a_changed_host_key_is_never_accepted_and_says_how_to_clear_it() {
    let ssh = FakeSsh::new(vec![failed(
        255,
        &[
            "@    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @",
            "Host key verification failed.",
        ],
    )]);
    let (outcome, _) = run("gcp-3", &ssh, &FakeHub::up()).await;
    let f = failure(&outcome);
    assert_eq!(f.kind, Kind::HostKeyChanged);
    assert!(f.next.contains("ssh-keygen -R gcp-3"), "{f:?}");
    one_line(f);
}

#[tokio::test]
async fn an_unreachable_host_says_so() {
    let ssh = FakeSsh::new(vec![failed(
        255,
        &["ssh: connect to host gcp-3 port 22: Connection refused"],
    )]);
    let (outcome, _) = run("gcp-3", &ssh, &FakeHub::up()).await;
    let f = failure(&outcome);
    assert_eq!(f.kind, Kind::Unreachable);
    assert!(f.message.contains("Connection refused"), "{f:?}");
    one_line(f);
}

#[tokio::test]
async fn windows_and_other_systems_are_an_unsupported_platform() {
    for reply in [
        failed(1, &["'uname' is not recognized as an internal or external command,"]),
        ok("FreeBSD amd64\n"),
        ok("Linux riscv64\n"),
    ] {
        let hub = FakeHub::up();
        let (outcome, _) = run("box", &FakeSsh::new(vec![reply]), &hub).await;
        let f = failure(&outcome);
        assert_eq!(f.kind, Kind::UnsupportedPlatform, "{f:?}");
        assert!(f.next.contains("macOS or Linux"), "{f:?}");
        one_line(f);
        assert_eq!(*hub.mints.lock().unwrap(), 0);
    }
    let windows = platform_of(&failed(1, &["'uname' is not recognized as an internal command"]));
    assert_eq!(windows, Err("Windows".to_owned()));
    assert_eq!(platform_of(&ok("Darwin arm64\n")), Ok("macOS arm64".to_owned()));
}

#[tokio::test]
async fn a_hub_this_computer_cannot_reach_says_so() {
    let ssh = FakeSsh::new(vec![ok("Linux x86_64\n")]);
    let hub = FakeHub { unreachable: true, ..FakeHub::up() };
    let (outcome, _) = run("gcp-3", &ssh, &hub).await;
    let f = failure(&outcome);
    assert_eq!(f.kind, Kind::HubUnreachable);
    assert!(f.message.contains(ORIGIN), "{f:?}");
    assert!(f.next.contains("this computer's internet"), "{f:?}");
    one_line(f);
}

#[tokio::test]
async fn a_far_machine_that_cannot_reach_the_hub_says_so() {
    let ssh = FakeSsh::new(vec![
        ok("Linux x86_64\n"),
        failed(4, &["cmux join: could not download the join script from https://hub.example.test"]),
    ]);
    let (outcome, _) = run("gcp-3", &ssh, &FakeHub::up()).await;
    let f = failure(&outcome);
    assert_eq!(f.kind, Kind::HubUnreachable);
    assert!(f.next.contains("gcp-3's internet"), "{f:?}");
    one_line(f);
}

#[tokio::test]
async fn a_refused_sign_in_says_to_sign_in() {
    let ssh = FakeSsh::new(vec![ok("Linux x86_64\n")]);
    let hub = FakeHub { mint: Err((401, "auth.unauthorized")), ..FakeHub::up() };
    let (outcome, _) = run("gcp-3", &ssh, &hub).await;
    let f = failure(&outcome);
    assert_eq!(f.kind, Kind::NotSignedIn);
    assert!(f.next.contains("cmux login"), "{f:?}");
    one_line(f);
}

#[tokio::test]
async fn an_expired_line_and_a_failed_script_name_their_next_step() {
    let expired =
        FakeSsh::new(vec![ok("Linux x86_64\n"), failed(3, &["cmux join: this line was used"])]);
    let (outcome, _) = run("gcp-3", &expired, &FakeHub::up()).await;
    assert_eq!(failure(&outcome).kind, Kind::Expired);
    one_line(failure(&outcome));

    let broke = FakeSsh::new(vec![
        ok("Linux x86_64\n"),
        failed(1, &["cmux join: the acpmux download's sha256 does not match"]),
    ]);
    let (outcome, _) = run("gcp-3", &broke, &FakeHub::up()).await;
    let f = failure(&outcome);
    assert_eq!(f.kind, Kind::Failed);
    assert!(f.message.contains("sha256 does not match"), "{f:?}");
    assert!(f.next.contains("cmux device doctor gcp-3"), "{f:?}");
    one_line(f);

    // ssh's own 255 after the script began is the script's link dropping, not a key problem.
    let dropped = FakeSsh::new(vec![
        ok("Linux x86_64\n"),
        failed(
            255,
            &["cmux join: installing acpmux", "Connection to gcp-3 closed by remote host."],
        ),
    ]);
    let (outcome, _) = run("gcp-3", &dropped, &FakeHub::up()).await;
    assert_eq!(failure(&outcome).kind, Kind::Failed);
}

#[tokio::test(start_paused = true)]
async fn a_daemon_that_never_reports_in_says_where_to_look() {
    let ssh = FakeSsh::new(vec![ok("Linux x86_64\n"), ok("")]);
    let hub = FakeHub { reports: false, ..FakeHub::up() };
    let (outcome, _) = run("gcp-3", &ssh, &hub).await;
    let f = failure(&outcome);
    assert_eq!(f.kind, Kind::NoReport);
    assert!(f.next.contains("cmux device doctor gcp-3"), "{f:?}");
    one_line(f);
}

#[tokio::test]
async fn option_like_hosts_and_unsafe_names_never_reach_ssh() {
    for (host, name) in [("-oProxyCommand=sh", None), ("gcp 3", None), ("gcp-3", Some("a'b"))] {
        let ssh = FakeSsh::new(Vec::new());
        let mut events = Vec::new();
        let req = Request { host: host.into(), name: name.map(str::to_owned), hub: None };
        let outcome = join(&req, &ssh, &FakeHub::up(), &mut |p| events.push(p)).await;
        assert_eq!(failure(&outcome).kind, Kind::Usage, "{host} {name:?}");
        assert!(ssh.seen().is_empty(), "{host}");
    }
}

#[test]
fn hub_rows_read_the_heartbeat_and_ignore_new_fields() {
    let body = json!({"machines": [{
        "machineId": "machine_01", "label": null, "name": "gcp-3", "joinTokenId": "join_01",
        "lastHeartbeat": "2026-11-16T10:00:00.000Z", "revoked": false, "windowsLine": "x",
    }]});
    let rows = rows(&body);
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0].name, "gcp-3");
    assert_eq!(rows[0].join_token_id.as_deref(), Some("join_01"));
    assert_eq!(rows[0].last_heartbeat_ms, Some(1_794_823_200_000));
}

fn node(name: &str, login: Option<&str>, tags: &[&str]) -> crate::tailnet::Node {
    crate::tailnet::Node {
        host_name: name.into(),
        dns_name: format!("{name}.tail9.ts.net"),
        os: "linux".into(),
        login: login.map(str::to_owned),
        tags: tags.iter().map(|t| (*t).to_owned()).collect(),
        ips: vec!["100.64.0.9".parse().unwrap()],
        online: true,
        shared: false,
    }
}

#[test]
fn only_a_tailnet_node_this_person_owns_joins_without_asking() {
    let me = Some("leo@example.com");
    let status = crate::tailnet::Status {
        backend_state: "Running".into(),
        this: node("this-mac", me, &[]),
        peers: vec![
            node("gcp-3", me, &[]),
            node("ci-box", None, &["tag:ci"]),
            node("friend", Some("sam@example.com"), &[]),
        ],
    };
    for host in ["gcp-3", "gcp-3.tail9.ts.net", "cmux@gcp-3", "GCP-3.tail9.ts.net."] {
        assert!(owned_tailnet_node(&status, host), "{host}");
    }
    for host in ["ci-box", "friend", "lab", "10.0.0.7"] {
        assert!(!owned_tailnet_node(&status, host), "{host}");
    }
    let ask = needs_confirmation("lab", Some("leo"));
    assert_eq!(ask.kind, Kind::NeedsConfirmation);
    assert!(ask.message.contains("lab") && ask.message.contains("as leo"), "{ask:?}");
    one_line(&ask);
}

/// Design rule (b): the join script's non-interactive mode. No tty (`-T`), no prompt
/// (`BatchMode`), `CMUX_JOIN_INTERACTIVE=0` so it asks for no vendor sign-in, and the token is
/// stdin's first line, never in argv.
#[test]
fn the_install_runs_the_join_script_non_interactively() {
    let plan = join_plan("ssh", ORIGIN, "gcp-3", None, TOKEN);
    assert_eq!(plan.argv.get(1).map(String::as_str), Some("-T"), "{:?}", plan.argv);
    assert!(plan.argv.iter().any(|w| w == "BatchMode=yes"));
    let remote = plan.argv.last().unwrap();
    assert!(remote.contains("CMUX_JOIN_INTERACTIVE=0 sh \"$f\""), "{remote}");
    assert!(remote.starts_with("sh -c 'IFS= read -r t || exit 2;"), "{remote}");
    assert_eq!(plan.stdin.as_deref().map(String::as_str), Some(format!("{TOKEN}\n").as_str()));
    assert!(plan.argv.iter().all(|w| !w.contains(TOKEN)));
}

/// Design rule (b): after the token line stdin closes, so nothing the join script runs can wait
/// on it or read a second line.
#[tokio::test]
async fn the_real_ssh_runner_closes_stdin_after_the_token_line() {
    let script = "IFS= read -r t || exit 9; [ \"$t\" = token-line ] || exit 8; \
                  if IFS= read -r more; then echo open; else echo closed; fi";
    let plan = SshPlan {
        argv: vec!["sh".into(), "-c".into(), script.into()],
        stdin: Some(Zeroizing::new("token-line\n".into())),
    };
    let mut lines = Vec::new();
    let ran = tokio::time::timeout(
        Duration::from_secs(10),
        ProcessSsh.run(plan, &mut |l: &str| lines.push(l.to_owned())),
    )
    .await
    .expect("stdin was left open")
    .unwrap();
    assert_eq!(ran.code, 0, "{ran:?}");
    assert_eq!(ran.stdout.trim(), "closed");
}
