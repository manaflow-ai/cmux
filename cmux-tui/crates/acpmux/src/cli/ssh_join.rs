//! Door A: add a machine this computer already reaches by key-only ssh, in one action
//! (cmuxterm-hq docs/design/remote-spin-up.md, section 2.1).
//!
//! Leo, 2026-11-16: "keep improving the usability and experience of the remote product. it should
//! not take much at all to simply spin shit up".
//!
//! One join underneath: the hub join (`cmux-tui/scripts/machine-join.sh`, served by the hub at
//! `/v1/machines/join.sh`). The script downloads the build for the far machine's own OS and
//! arch, so a Mac sets up a Linux box (the copy-this-binary enroll cannot). The steps:
//!
//! 1. `reach`: `uname -sm` over ssh with `BatchMode=yes`, so ssh never asks for a password or a
//!    passphrase. It proves the key works and says which join script fits the machine (only the
//!    POSIX one today; Windows is a clear "unsupported platform").
//! 2. `token`: one single-use join token minted with the person's access token.
//! 3. `install`: the join script on the host, the token on ssh's stdin. It is never in an argument
//!    list on either side: the remote shell `read`s it into a variable and hands it to the
//!    script's environment, as the pasted line does.
//! 4. `connect`: the hub's machine list until the machine's daemon reports in.
//!
//! `cmux device add HOST --yes --hub` runs this in its own process, and the daemon's
//! `_acpmux/machine_join_ssh` runs it for the app with the same steps sent as progress
//! notifications. Every failure names its next step in one line ([`Failure::next`]).

use std::future::Future;
use std::pin::Pin;
use std::time::{Duration, Instant};

use cmux_json::JsonSet as _;
use serde::Serialize;
use serde_json::{Value, json};
use zeroize::Zeroizing;

/// The capability that lists `_acpmux/machine_join_ssh` and `_acpmux/machine_candidates`.
pub const CAPABILITY: &str = "machine-join-ssh-v1";
/// The ssh program; `CMUX_JOIN_SSH` names another (a wrapper that adds `-F FILE`, as `GIT_SSH`).
pub const SSH_ENV: &str = "CMUX_JOIN_SSH";
/// ssh's own exit code for "could not connect or authenticate".
const SSH_FAILED: i32 = 255;
/// The join line lives this long; the whole join fits in it with room.
const TOKEN_TTL_SECS: u64 = 600;
/// How long `connect` waits for the daemon's first report once the script is done.
const CONNECT_WITHIN: Duration = Duration::from_secs(60);
const CONNECT_EVERY: Duration = Duration::from_millis(1000);
/// The script's last lines kept to explain a failure.
const TAIL_LINES: usize = 12;

/// What to join.
#[derive(Clone, Debug, Default)]
pub struct Request {
    /// An ssh destination: `HOST`, `USER@HOST` or an alias of `~/.ssh/config`.
    pub host: String,
    /// The machine's name in cmux; the far machine's own hostname when absent.
    pub name: Option<String>,
    /// The hub's origin; `CMUX_PLATFORM_ORIGIN`, else production, when absent.
    pub hub: Option<String>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Step {
    Reach,
    Token,
    Install,
    Connect,
}

impl Step {
    pub fn as_str(self) -> &'static str {
        match self {
            Step::Reach => "reach",
            Step::Token => "token",
            Step::Install => "install",
            Step::Connect => "connect",
        }
    }

    /// The progress line's verb: "Setting up gcp-3 · installing 6 s".
    pub fn doing(self) -> &'static str {
        match self {
            Step::Reach => "connecting",
            Step::Token => "getting a join line",
            Step::Install => "installing",
            Step::Connect => "waiting for it to report in",
        }
    }
}

/// One progress event.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Progress {
    pub step: Step,
    /// `running` while the step goes on, `ok` when it is done.
    pub state: &'static str,
    /// The step's own words: the far machine's OS, the join script's last line.
    pub detail: String,
    /// Since the join began.
    pub seconds: u64,
}

/// Why a join stopped, as a kind the app can branch on.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Kind {
    /// ssh refused every key (or asked for a password, which `BatchMode` never answers).
    NeedsKey,
    /// The host key differs from the one known for this host.
    HostKeyChanged,
    /// ssh could not connect at all.
    Unreachable,
    /// Not macOS or Linux on arm64 or x86_64.
    UnsupportedPlatform,
    /// This computer or the far machine cannot reach the hub.
    HubUnreachable,
    /// The access token was refused: not signed in, or signed out since.
    NotSignedIn,
    /// The hub refused the join token (a limit, a role).
    Refused,
    /// The join line expired or was used before the far machine redeemed it.
    Expired,
    /// The join ran but the daemon never reported in.
    NoReport,
    /// The far machine kept an earlier join and redeemed nothing (an acpmux whose probe told no
    /// join status).
    AlreadyJoined,
    /// The join script failed for its own reason; its last line says which.
    Failed,
    /// A bad request (an option-like host, a name with spaces).
    Usage,
    /// The host is not a tailnet node this person owns: the app asks once, naming the host and
    /// the ssh login, then calls again with `confirmed`.
    NeedsConfirmation,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Failure {
    pub kind: Kind,
    /// What happened, in one line.
    pub message: String,
    /// The next step, in one line.
    pub next: String,
}

impl Failure {
    fn new(kind: Kind, message: impl Into<String>, next: impl Into<String>) -> Self {
        Self { kind, message: message.into(), next: next.into() }
    }
}

/// The machine once its daemon reported in.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Joined {
    pub machine_id: String,
    pub name: String,
    /// The host name the machine reported (`ubuntu`): an acpmux released before the mesh took
    /// the joined name heartbeats with it, so the hub's mesh lists the machine by it.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub hostname: Option<String>,
}

/// The whole join's answer.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Outcome {
    pub ok: bool,
    pub host: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub machine: Option<Joined>,
    /// The far machine as `uname -sm` says it (`Linux x86_64`).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub platform: Option<String>,
    pub seconds: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub failure: Option<Failure>,
    /// Earlier records of this machine under the same name that the join revoked
    /// ([`replace_earlier`]), by machine id.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub replaced: Vec<String>,
    /// The machine was already joined to this account with its daemon up: its record (`machine`)
    /// is kept, and no join token was minted.
    #[serde(rename = "alreadyJoined", skip_serializing_if = "std::ops::Not::not")]
    pub already_joined: bool,
}

impl Outcome {
    pub fn to_value(&self) -> Value {
        serde_json::to_value(self).unwrap_or_else(|_| json!({"ok": self.ok}))
    }
}

pub type BoxFut<'a, T> = Pin<Box<dyn Future<Output = T> + Send + 'a>>;

/// What one ssh run did.
#[derive(Clone, Debug, Default)]
pub struct Ran {
    pub code: i32,
    pub stdout: String,
    /// The last [`TAIL_LINES`] lines of stderr.
    pub stderr: Vec<String>,
}

/// One ssh invocation: its argv (never a token) and what goes to its stdin.
pub struct SshPlan {
    pub argv: Vec<String>,
    pub stdin: Option<Zeroizing<String>>,
}

impl std::fmt::Debug for SshPlan {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let stdin = self.stdin.as_ref().map(|_| "***");
        f.debug_struct("SshPlan").field("argv", &self.argv).field("stdin", &stdin).finish()
    }
}

/// Runs ssh; `line` gets every output line as it comes (the join script's progress).
pub trait Ssh: Send + Sync {
    fn run<'a>(
        &'a self,
        plan: SshPlan,
        line: &'a mut (dyn FnMut(&str) + Send),
    ) -> BoxFut<'a, std::io::Result<Ran>>;
}

/// A minted join token.
pub struct Minted {
    pub token: Zeroizing<String>,
    pub join_token_id: String,
}

/// How a hub call failed.
#[derive(Debug)]
pub enum HubError {
    Unreachable(String),
    Status { status: u16, code: String },
}

/// One row of the hub's machine list, as `connect` reads it.
#[derive(Clone, Debug, Default)]
pub struct Row {
    pub machine_id: String,
    pub name: String,
    pub join_token_id: Option<String>,
    pub last_heartbeat_ms: Option<u64>,
    pub revoked: bool,
    /// The host name the machine reported at its join.
    pub hostname: Option<String>,
}

/// The hub as the signed-in person.
pub trait Hub: Send + Sync {
    fn origin(&self) -> &str;
    fn mint<'a>(&'a self, label: Option<&'a str>) -> BoxFut<'a, Result<Minted, HubError>>;
    fn machines(&self) -> BoxFut<'_, Result<Vec<Row>, HubError>>;
    /// Revokes the person's machine `machine_id`.
    fn revoke<'a>(&'a self, machine_id: &'a str) -> BoxFut<'a, Result<(), HubError>>;
    /// Records where a token minted here went ([`ledger`]).
    fn remember(&self, entry: ledger::Entry);
    /// Where the token `join_token_id` went, if this computer minted it.
    fn remembered(&self, join_token_id: &str) -> Option<ledger::Entry>;
}

/// A host ssh takes as one word: never an option (`-oProxyCommand=…`), a space, a quote or a
/// control character.
pub fn valid_host(host: &str) -> bool {
    (1..=255).contains(&host.len())
        && !host.starts_with('-')
        && host.bytes().all(|b| b.is_ascii_graphic() && !matches!(b, b'\'' | b'"' | b'\\' | b'`'))
}

/// A machine name the hub takes and a remote shell holds unquoted inside single quotes.
pub fn valid_name(name: &str) -> bool {
    (1..=63).contains(&name.len())
        && name.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-'))
        && !name.starts_with(['-', '.'])
}

/// An origin safe unquoted in a remote shell command.
fn shell_safe_origin(origin: &str) -> bool {
    !origin.is_empty()
        && origin
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b':' | b'/' | b'.' | b'-' | b'_'))
}

/// The login ssh would use for `host` (`ssh -G`, which reads the config and connects nowhere).
pub fn ssh_login(program: &str, host: &str) -> Option<String> {
    if !valid_host(host) {
        return None;
    }
    let out = cmux_process::Command::new(program)
        .args(["-G", "--", host])
        .stdin(cmux_process::Stdio::null())
        .output()
        .ok()?;
    String::from_utf8_lossy(&out.stdout)
        .lines()
        .find_map(|line| line.strip_prefix("user ").map(str::trim).map(str::to_owned))
        .filter(|user| !user.is_empty())
}

/// Whether `host` (`HOST` or `USER@HOST`) names a node of the tailnet that the tailnet says
/// this person owns (`mine`: their login, not tagged, not shared in): the one kind of host one
/// click joins without asking.
pub fn owned_tailnet_node(status: &crate::tailnet::Status, host: &str) -> bool {
    let bare =
        host.rsplit_once('@').map_or(host, |(_, h)| h).trim_end_matches('.').to_ascii_lowercase();
    super::host_candidates::candidates(status, &[]).iter().any(|c| {
        c.mine
            && (c.name.eq_ignore_ascii_case(&bare)
                || c.dns_name.eq_ignore_ascii_case(&bare)
                || c.ip.as_deref() == Some(bare.as_str()))
    })
}

/// The refusal that asks the person to confirm `host` and `login` once.
pub fn needs_confirmation(host: &str, login: Option<&str>) -> Failure {
    let who = login.map(|l| format!(" as {l}")).unwrap_or_default();
    Failure::new(
        Kind::NeedsConfirmation,
        format!("{host} is not one of your own tailnet machines: confirm adding it{who}"),
        format!("confirm \"Add {host}{who}\" to join it"),
    )
}

/// The ssh program: `CMUX_JOIN_SSH`, else `ssh`.
pub fn ssh_program() -> String {
    std::env::var(SSH_ENV).ok().filter(|p| !p.trim().is_empty()).unwrap_or_else(|| "ssh".into())
}

/// ssh's options for every step: never a prompt (a password, a passphrase, a new host key: a
/// first contact is accepted, since the person named this host to add; a changed key never is),
/// and a dead link noticed in 30 s.
fn ssh_argv(program: &str, host: &str, remote: &str) -> Vec<String> {
    [
        program,
        "-T",
        "-o",
        "BatchMode=yes",
        "-o",
        "StrictHostKeyChecking=accept-new",
        "-o",
        "ConnectTimeout=15",
        "-o",
        "ServerAliveInterval=10",
        "-o",
        "ServerAliveCountMax=3",
        "-o",
        "LogLevel=ERROR",
        "--",
        host,
        remote,
    ]
    .map(str::to_owned)
    .to_vec()
}

/// `reach`: the far machine's OS and arch, then its ssh host key (for [`host_key_of`]), then its
/// acpmux's join status on one line (for [`joined_there`]). A system with no `uname` (Windows)
/// fails at the first command, before the `&&`.
pub fn probe_plan(program: &str, host: &str) -> SshPlan {
    SshPlan { argv: ssh_argv(program, host, PROBE), stdin: None }
}

/// The probe's remote command.
const PROBE: &str = "uname -sm && { cat /etc/ssh/ssh_host_ed25519_key.pub 2>/dev/null || cat /etc/ssh/ssh_host_ecdsa_key.pub 2>/dev/null || true; } && { ~/.local/bin/acpmux host join --status --json 2>/dev/null | tr -d '\\r\\n'; echo; }";

/// The far machine's live join, from the probe's status line.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct JoinedThere {
    /// The machine id its credential is for.
    pub machine_id: Option<String>,
    /// Its daemon answered the status.
    pub daemon_running: bool,
}

/// The far machine's join as the probe's `host join --status` line says, when it holds a live
/// credential: the join script then redeems nothing unless `CMUX_JOIN_REPLACE=1` ("already
/// joined; nothing redeemed"). None when it holds none, it was revoked, a join was cut short (the
/// script resumes that one), it is a copy of another box, or no acpmux answered.
pub fn joined_there(reply: &Ran) -> Option<JoinedThere> {
    reply.stdout.lines().skip(1).find_map(|line| {
        let status: Value = serde_json::from_str(line.trim()).ok()?;
        let yes = |key: &str| status.get(key).and_then(Value::as_bool) == Some(true);
        let live =
            yes("credentialPresent") && !yes("revoked") && !yes("joinIncomplete") && !yes("cloned");
        live.then(|| JoinedThere {
            machine_id: status
                .get("machineId")
                .and_then(Value::as_str)
                .filter(|id| !id.is_empty())
                .map(str::to_owned),
            daemon_running: yes("daemonRunning"),
        })
    })
}

/// The join script's line when the machine kept its credential and redeemed nothing.
const NOTHING_REDEEMED: &str = "already joined; nothing redeemed";

/// The far machine's ssh host key from the probe's answer, as OpenSSH prints its fingerprint
/// (`SHA256:` and the unpadded base64 of the key blob's SHA-256), or None when it printed none.
pub fn host_key_of(reply: &Ran) -> Option<String> {
    use base64::Engine as _;
    use sha2::Digest as _;
    reply.stdout.lines().skip(1).find_map(|line| {
        let mut words = line.split_whitespace();
        let kind = words.next()?;
        if !(kind.starts_with("ssh-") || kind.starts_with("ecdsa-")) {
            return None;
        }
        let blob = base64::engine::general_purpose::STANDARD.decode(words.next()?).ok()?;
        let digest = sha2::Sha256::digest(&blob);
        Some(format!("SHA256:{}", base64::engine::general_purpose::STANDARD_NO_PAD.encode(digest)))
    })
}

/// `install`: the remote shell reads the token from stdin into an unexported variable, downloads
/// the join script to a temp file (a failed download exits 4, the script's own "hub
/// unreachable", and never runs an empty script) and runs it with the token in its environment.
/// Its exit code is the join's. `replace` swaps a credential the machine already holds
/// (`CMUX_JOIN_REPLACE=1`), so the new token is redeemed.
pub fn join_plan(
    program: &str,
    origin: &str,
    host: &str,
    name: Option<&str>,
    replace: bool,
    token: &str,
) -> SshPlan {
    let mut name = name.map(|name| format!(" CMUX_JOIN_NAME={name}")).unwrap_or_default();
    if replace {
        name.push_str(" CMUX_JOIN_REPLACE=1");
    }
    let remote = format!(
        "sh -c 'IFS= read -r t || exit 2; f=$(mktemp \"${{TMPDIR:-/tmp}}/cmux-join.XXXXXX\") || exit 1; trap \"rm -f -- \\\"\\$f\\\"\" EXIT; curl -fsSL --connect-timeout 15 {origin}/v1/machines/join.sh -o \"$f\" || {{ echo \"cmux join: could not download the join script from {origin}\" >&2; exit 4; }}; CMUX_JOIN=\"$t\" CMUX_JOIN_INTERACTIVE=0{name} sh \"$f\"'"
    );
    SshPlan {
        argv: ssh_argv(program, host, &remote),
        stdin: Some(Zeroizing::new(format!("{token}\n"))),
    }
}

/// `uname -sm` as a platform the POSIX join script serves, or why not.
pub fn platform_of(reply: &Ran) -> Result<String, String> {
    // The first line: the host key follows it ([`PROBE`]).
    let text = reply.stdout.trim().lines().next().unwrap_or_default().trim();
    let mut words = text.split_whitespace();
    let (os, arch) = (words.next().unwrap_or_default(), words.next().unwrap_or_default());
    let known_os = matches!(os, "Linux" | "Darwin");
    let known_arch = matches!(arch, "x86_64" | "amd64" | "aarch64" | "arm64");
    if reply.code == 0 && known_os && known_arch {
        return Ok(format!("{} {arch}", if os == "Darwin" { "macOS" } else { os }));
    }
    let said = reply.stderr.join(" ");
    // Windows' OpenSSH runs cmd.exe or PowerShell, which have no `uname`.
    if said.contains("is not recognized") || said.contains("CommandNotFoundException") {
        return Err("Windows".into());
    }
    Err(if text.is_empty() { "an unknown system".into() } else { text.to_owned() })
}

/// ssh's own failure (exit 255) as its next step.
pub fn ssh_failure(host: &str, ran: &Ran) -> Failure {
    let said = ran.stderr.join("\n");
    let last = ran.stderr.iter().rev().find(|l| !l.trim().is_empty()).cloned().unwrap_or_default();
    if said.contains("REMOTE HOST IDENTIFICATION HAS CHANGED")
        || said.contains("Host key verification failed")
    {
        return Failure::new(
            Kind::HostKeyChanged,
            format!("{host}'s ssh host key is not the one this computer knows"),
            format!("if you expect a new key there, run `ssh-keygen -R {host}`, then add it again"),
        );
    }
    if said.contains("Permission denied")
        || said.contains("Too many authentication failures")
        || said.contains("No supported authentication methods")
    {
        return Failure::new(
            Kind::NeedsKey,
            format!("ssh to {host} needs a key: it refused this computer's keys"),
            format!(
                "run `ssh-copy-id {host}` once (or add your public key to its ~/.ssh/authorized_keys), then add it again"
            ),
        );
    }
    Failure::new(
        Kind::Unreachable,
        if last.is_empty() {
            format!("ssh could not reach {host}")
        } else {
            format!("ssh could not reach {host}: {last}")
        },
        format!(
            "check that {host} is on and accepts ssh (`ssh {host}` works here), then add it again"
        ),
    )
}

/// The join script's failure (its exit code and last lines) as its next step.
pub fn script_failure(host: &str, origin: &str, ran: &Ran) -> Failure {
    let last = ran
        .stderr
        .iter()
        .rev()
        .find(|l| !l.trim().is_empty())
        .map(|l| l.trim().to_owned())
        .unwrap_or_default();
    let said = |words: &str| ran.stderr.iter().any(|l| l.contains(words));
    match ran.code {
        4 => Failure::new(
            Kind::HubUnreachable,
            format!("{host} cannot reach the cmux hub at {origin}"),
            format!("check {host}'s internet connection or proxy, then add it again"),
        ),
        3 => Failure::new(
            Kind::Expired,
            format!("the join line expired or was used before {host} redeemed it"),
            "add it again: each try makes a new line",
        ),
        1 if said("unsupported platform") => Failure::new(
            Kind::UnsupportedPlatform,
            format!("{host} is not a platform cmux runs on: {last}"),
            "add a macOS or Linux machine (arm64 or x86_64)",
        ),
        1 if said("no curl") => Failure::new(
            Kind::Failed,
            format!("{host} has no working curl: {last}"),
            format!("install curl on {host}, then add it again"),
        ),
        code => Failure::new(
            Kind::Failed,
            if last.is_empty() {
                format!("the join on {host} stopped (exit {code})")
            } else {
                format!("the join on {host} stopped (exit {code}): {last}")
            },
            format!("run `cmux device doctor {host}` to see what is missing there"),
        ),
    }
}

/// A hub refusal as its next step.
pub fn hub_failure(origin: &str, error: &HubError) -> Failure {
    match error {
        HubError::Unreachable(why) => Failure::new(
            Kind::HubUnreachable,
            format!("this computer cannot reach the cmux hub at {origin} ({why})"),
            "check this computer's internet connection, then add it again",
        ),
        HubError::Status { status: 401, .. } => Failure::new(
            Kind::NotSignedIn,
            "the cmux hub did not accept this sign-in",
            "sign in to cmux on this computer (`cmux login`), then add it again",
        ),
        // The platform's meanings (cmux-cloud-client openapi.json, `machineJoin.mint`): 404 is
        // `MachineNotFound`, "the machine or enabled API surface is absent; check the identifier
        // and deployment": that hub serves no machine joins (another deployment's origin, or
        // joins off there), never a missing permission. Only 403 `machine.not_member` is the
        // team's owner's to change.
        HubError::Status { status: 404, code } => Failure::new(
            Kind::Refused,
            format!(
                "the cmux hub at {origin} has no machine joins (HTTP 404 {code}): it is another deployment, or joining is off there"
            ),
            "check which hub this computer signs in to (--platform, or CMUX_PLATFORM_ORIGIN) and that its token is from that hub (`cmux login` there), then add it again",
        ),
        HubError::Status { status: 403, code } if code == "machine.not_member" => Failure::new(
            Kind::Refused,
            format!("the cmux hub refused a join line (HTTP 403 {code})"),
            "ask your team's owner to let you add machines, then add it again",
        ),
        HubError::Status { status: 429, code } => Failure::new(
            Kind::Refused,
            format!("the cmux hub refused a join line for now (HTTP 429 {code})"),
            "wait a minute, then add it again",
        ),
        HubError::Status { status: 503, code } => Failure::new(
            Kind::HubUnreachable,
            format!("the cmux hub cannot add machines right now (HTTP 503 {code})"),
            "add it again in a few minutes",
        ),
        HubError::Status { status, code } => Failure::new(
            Kind::Refused,
            format!("the cmux hub refused a join line (HTTP {status} {code})"),
            "add it again; if the hub refuses again, sign in to cmux again (`cmux login`)",
        ),
    }
}

/// Runs the join: every step's progress goes to `emit`, then the answer.
pub async fn join(
    request: &Request,
    ssh: &dyn Ssh,
    hub: &dyn Hub,
    emit: &mut (dyn FnMut(Progress) + Send),
) -> Outcome {
    let started = Instant::now();
    let host = request.host.clone();
    let mut outcome = Outcome {
        ok: false,
        host: host.clone(),
        machine: None,
        platform: None,
        seconds: 0,
        failure: None,
        replaced: Vec::new(),
        already_joined: false,
    };
    let result = steps(request, ssh, hub, started, &mut outcome, emit).await;
    outcome.seconds = started.elapsed().as_secs();
    match result {
        Ok(machine) => {
            outcome.ok = true;
            outcome.machine = Some(machine);
        }
        Err(failure) => outcome.failure = Some(failure),
    }
    outcome
}

async fn steps(
    request: &Request,
    ssh: &dyn Ssh,
    hub: &dyn Hub,
    started: Instant,
    outcome: &mut Outcome,
    emit: &mut (dyn FnMut(Progress) + Send),
) -> Result<Joined, Failure> {
    let host = request.host.as_str();
    if !valid_host(host) {
        return Err(Failure::new(
            Kind::Usage,
            format!("{host:?} is not an ssh host"),
            "name the machine as ssh does: HOST, USER@HOST or an alias of ~/.ssh/config",
        ));
    }
    if let Some(name) = request.name.as_deref().filter(|name| !valid_name(name)) {
        return Err(Failure::new(
            Kind::Usage,
            format!("{name:?} is not a machine name"),
            "use 1 to 63 letters, digits, dots, dashes or underscores",
        ));
    }
    let origin = hub.origin().to_owned();
    if !shell_safe_origin(&origin) {
        return Err(Failure::new(
            Kind::Usage,
            format!("the hub origin {origin:?} cannot go in a remote command"),
            "use the pasted join line instead (cmux machine add)",
        ));
    }
    let seconds = || started.elapsed().as_secs();
    let program = ssh_program();

    emit(Progress {
        step: Step::Reach,
        state: "running",
        detail: host.to_owned(),
        seconds: seconds(),
    });
    let probe = ssh
        .run(probe_plan(&program, host), &mut |_| {})
        .await
        .map_err(|e| cannot_run_ssh(&program, &e))?;
    if probe.code == SSH_FAILED {
        return Err(ssh_failure(host, &probe));
    }
    let platform = platform_of(&probe).map_err(|what| {
        Failure::new(
            Kind::UnsupportedPlatform,
            format!("{host} runs {what}: the ssh join sets up only macOS and Linux"),
            "add a macOS or Linux machine (arm64 or x86_64)",
        )
    })?;
    outcome.platform = Some(platform.clone());
    let host_key = host_key_of(&probe);
    // A machine already joined redeems a new token only with CMUX_JOIN_REPLACE=1 (Door A live
    // rerun, 2026-11-16: a re-add a minute after the first said "already joined; nothing
    // redeemed", then waited 60 s for a machine that never came). Joined to this account with its
    // daemon up, it is kept as it is and nothing is minted; any other live join (another account,
    // another name asked for, a daemon down) is swapped for the new token.
    let there = joined_there(&probe);
    let mut replace = false;
    if let Some(there) = &there {
        let rows = hub.machines().await.map_err(|e| hub_failure(&origin, &e))?;
        match kept_record(rows, there, request.name.as_deref()) {
            Some(machine) => {
                emit(Progress {
                    step: Step::Reach,
                    state: "ok",
                    detail: platform,
                    seconds: seconds(),
                });
                outcome.already_joined = true;
                outcome.replaced =
                    replace_earlier(hub, &machine, host, host_key.as_deref(), None).await;
                emit(Progress {
                    step: Step::Connect,
                    state: "ok",
                    detail: format!("already joined as {}", machine.name),
                    seconds: seconds(),
                });
                return Ok(machine);
            }
            None => replace = true,
        }
    }
    emit(Progress { step: Step::Reach, state: "ok", detail: platform, seconds: seconds() });

    emit(Progress {
        step: Step::Token,
        state: "running",
        detail: String::new(),
        seconds: seconds(),
    });
    let minted = hub.mint(request.name.as_deref()).await.map_err(|e| hub_failure(&origin, &e))?;
    // Before the install: an add that fails after the script redeemed the token is known too.
    if let Some(host_key) = &host_key {
        hub.remember(ledger::Entry {
            join_token_id: minted.join_token_id.clone(),
            host: host.to_owned(),
            host_key: host_key.clone(),
        });
    }
    emit(Progress { step: Step::Token, state: "ok", detail: String::new(), seconds: seconds() });

    emit(Progress {
        step: Step::Install,
        state: "running",
        detail: String::new(),
        seconds: seconds(),
    });
    let plan = join_plan(&program, &origin, host, request.name.as_deref(), replace, &minted.token);
    drop(minted.token);
    let mut redeemed_nothing = false;
    let ran = {
        let mut line = |text: &str| {
            redeemed_nothing |= text.contains(NOTHING_REDEEMED);
            // The script's own lines (`cmux join: installing acpmux …`) are the progress.
            let detail = text.trim().trim_start_matches("cmux join:").trim();
            if !detail.is_empty() {
                emit(Progress {
                    step: Step::Install,
                    state: "running",
                    detail: detail.to_owned(),
                    seconds: started.elapsed().as_secs(),
                });
            }
        };
        ssh.run(plan, &mut line).await.map_err(|e| cannot_run_ssh(&program, &e))?
    };
    match ran.code {
        0 => {}
        SSH_FAILED if !ran.stderr.iter().any(|l| l.contains("cmux join:")) => {
            return Err(ssh_failure(host, &ran));
        }
        _ => return Err(script_failure(host, &origin, &ran)),
    }
    if redeemed_nothing {
        // The probe saw no live join (an acpmux with no status), yet the script kept one: the
        // new token's machine never comes, so waiting for it is a minute of nothing.
        return Err(Failure::new(
            Kind::AlreadyJoined,
            format!("{host} is already joined, so its join redeemed nothing"),
            format!(
                "it keeps its earlier join (`cmux device list`); to swap it, run the join on {host} with CMUX_JOIN_REPLACE=1"
            ),
        ));
    }
    emit(Progress { step: Step::Install, state: "ok", detail: String::new(), seconds: seconds() });

    emit(Progress {
        step: Step::Connect,
        state: "running",
        detail: String::new(),
        seconds: seconds(),
    });
    let Some(machine) = reported(hub, &minted.join_token_id, started).await else {
        return Err(no_report(hub, host, there.as_ref(), host_key.as_deref()).await);
    };
    let swapped = there.as_ref().and_then(|there| there.machine_id.as_deref());
    outcome.replaced = replace_earlier(hub, &machine, host, host_key.as_deref(), swapped).await;
    emit(Progress {
        step: Step::Connect,
        state: "ok",
        detail: machine.name.clone(),
        seconds: seconds(),
    });
    Ok(machine)
}

/// The record a machine already joined to this account keeps: its credential's machine is listed
/// and not revoked, its daemon is up, and the add asked for no other name.
fn kept_record(rows: Vec<Row>, there: &JoinedThere, name: Option<&str>) -> Option<Joined> {
    let id = there.machine_id.as_deref().filter(|_| there.daemon_running)?;
    let row = rows.into_iter().find(|row| row.machine_id == id && !row.revoked)?;
    if name.is_some_and(|name| !name.eq_ignore_ascii_case(&row.name)) {
        return None;
    }
    Some(Joined { machine_id: row.machine_id, name: row.name, hostname: row.hostname })
}

/// Whether `row`'s token went, from this computer, to `host` with the ssh host key `host_key`.
fn same_machine(hub: &dyn Hub, row: &Row, host: &str, host_key: &str) -> bool {
    row.join_token_id
        .as_deref()
        .and_then(|id| hub.remembered(id))
        .is_some_and(|entry| entry.host == host && entry.host_key == host_key)
}

/// The daemon never reported with the new token. When the hub lists this machine reporting under
/// an earlier join (the id it held, or a token this computer sent to the same host and host key),
/// its daemon is up: the next step is not doctor.
async fn no_report(
    hub: &dyn Hub,
    host: &str,
    there: Option<&JoinedThere>,
    host_key: Option<&str>,
) -> Failure {
    let message = format!(
        "{host} ran the join but its daemon has not reported in for {} s",
        CONNECT_WITHIN.as_secs()
    );
    let fresh_ms = now_ms().saturating_sub(CONNECT_WITHIN.as_secs().saturating_mul(2_000));
    let held = there.and_then(|there| there.machine_id.as_deref());
    let earlier = hub.machines().await.ok().and_then(|rows| {
        rows.into_iter().find(|row| {
            !row.revoked
                && row.last_heartbeat_ms.is_some_and(|at| at >= fresh_ms)
                && (held == Some(row.machine_id.as_str())
                    || host_key.is_some_and(|key| same_machine(hub, row, host, key)))
        })
    });
    match earlier {
        Some(row) => Failure::new(
            Kind::NoReport,
            format!("{message}: it reports as {} under an earlier join", row.name),
            format!("its daemon is up: use it as {}, or add it again to swap its join", row.name),
        ),
        None => Failure::new(
            Kind::NoReport,
            message,
            format!("run `cmux device doctor {host}` to see why its daemon is not running"),
        ),
    }
}

fn cannot_run_ssh(program: &str, error: &std::io::Error) -> Failure {
    Failure::new(
        Kind::Unreachable,
        format!("cannot run {program} ({:?})", error.kind()),
        "install OpenSSH's ssh on this computer, then add it again",
    )
}

/// The machine the join token made, once its daemon reported in after the join began: a
/// heartbeat newer than the start (with a minute of clock skew allowed) or, for a hub that sends
/// none, the row itself.
async fn reported(hub: &dyn Hub, join_token_id: &str, started: Instant) -> Option<Joined> {
    let began_ms = now_ms().saturating_sub(started.elapsed().as_millis() as u64);
    let deadline = tokio::time::Instant::now() + CONNECT_WITHIN;
    loop {
        if let Ok(rows) = hub.machines().await {
            let row = rows
                .into_iter()
                .find(|row| row.join_token_id.as_deref() == Some(join_token_id) && !row.revoked);
            if let Some(row) = row
                && row.last_heartbeat_ms.is_some_and(|at| at + 60_000 >= began_ms)
            {
                return Some(Joined {
                    machine_id: row.machine_id,
                    name: row.name,
                    hostname: row.hostname,
                });
            }
        }
        if tokio::time::Instant::now() + CONNECT_EVERY > deadline {
            return None;
        }
        tokio::time::sleep(CONNECT_EVERY).await;
    }
}

/// Revokes the records an earlier add of this same machine left under `joined`'s name: rows with
/// that name, not revoked, whose token this computer minted for the same ssh destination and the
/// same ssh host key (the [`ledger`]). A machine keeps one join record, so once it reported in
/// with the new one the old one speaks for nothing; left, it made a second machine of that name
/// and `cmux chat --on NAME` refused to pick. `swapped`, the credential the join replaced on the
/// machine itself, goes too, whatever its name. A machine of that name on another box, or one
/// this computer did not add, is never touched. Answers the revoked machine ids.
async fn replace_earlier(
    hub: &dyn Hub,
    joined: &Joined,
    host: &str,
    host_key: Option<&str>,
    swapped: Option<&str>,
) -> Vec<String> {
    if host_key.is_none() && swapped.is_none() {
        return Vec::new();
    }
    let Ok(rows) = hub.machines().await else { return Vec::new() };
    let mut replaced = Vec::new();
    for row in rows {
        let earlier_add = row.name.eq_ignore_ascii_case(&joined.name)
            && host_key.is_some_and(|key| same_machine(hub, &row, host, key));
        if row.revoked
            || row.machine_id == joined.machine_id
            || !(earlier_add || swapped == Some(row.machine_id.as_str()))
        {
            continue;
        }
        match hub.revoke(&row.machine_id).await {
            Ok(()) => replaced.push(row.machine_id),
            Err(error) => tracing::warn!(
                machine = %row.machine_id,
                "the join could not revoke this machine's earlier record ({error:?})"
            ),
        }
    }
    replaced
}

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_millis() as u64)
}

/// The real ssh: a child of this process, killed when the join is dropped (a cancelled request).
pub struct ProcessSsh;

impl Ssh for ProcessSsh {
    fn run<'a>(
        &'a self,
        plan: SshPlan,
        line: &'a mut (dyn FnMut(&str) + Send),
    ) -> BoxFut<'a, std::io::Result<Ran>> {
        Box::pin(async move {
            use std::io::{BufRead as _, Write as _};
            let (program, args) =
                plan.argv.split_first().ok_or_else(|| std::io::Error::other("no ssh"))?;
            let mut command = cmux_process::Command::new(program);
            command
                .args(args)
                .stdin(cmux_process::Stdio::piped())
                .stdout(cmux_process::Stdio::piped())
                .stderr(cmux_process::Stdio::piped())
                .process_group(0);
            // Its owner: dropped while it runs (a cancelled request), it ends ssh's group.
            let mut child = command.spawn()?;
            if let Some(mut pipe) = child.stdin.take() {
                if let Some(input) = &plan.stdin {
                    // An ssh that ended early closes the pipe: its exit code says why.
                    let _ = pipe.write_all(input.as_bytes());
                }
                drop(pipe);
            }
            let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<(bool, String)>();
            let out = child.stdout.take().map(|s| Box::new(s) as Box<dyn std::io::Read + Send>);
            let err = child.stderr.take().map(|s| Box::new(s) as Box<dyn std::io::Read + Send>);
            for (is_err, reader) in [(false, out), (true, err)] {
                let Some(reader) = reader else { continue };
                let tx = tx.clone();
                // Each pipe read to its end on the blocking pool; the lines come back here.
                tokio::task::spawn_blocking(move || {
                    for text in std::io::BufReader::new(reader).lines() {
                        let Ok(text) = text else { break };
                        if tx.send((is_err, text)).is_err() {
                            break;
                        }
                    }
                });
            }
            drop(tx);
            let mut ran = Ran::default();
            while let Some((is_err, text)) = rx.recv().await {
                line(&text);
                if is_err {
                    ran.stderr.push(text);
                    if ran.stderr.len() > TAIL_LINES {
                        ran.stderr.remove(0);
                    }
                } else if ran.stdout.len() < 64 * 1024 {
                    ran.stdout.push_str(&text);
                    ran.stdout.push('\n');
                }
            }
            // Both pipes are closed, so ssh has exited: the wait is a reap.
            ran.code = child.wait()?.code().unwrap_or(SSH_FAILED);
            Ok(ran)
        })
    }
}

/// The hub as the person whose access token this is.
pub struct PersonHub {
    origin: String,
    client: cmux_cloud_client::Client,
}

impl PersonHub {
    /// `hub` (else `CMUX_PLATFORM_ORIGIN`, else production) as the person with `access`.
    pub fn new(hub: Option<String>, access: &str) -> anyhow::Result<Self> {
        let origin = super::cloud_join::hub_origin_or_default(hub)?;
        let client = super::cloud_join::hub_client(&origin, Some(access))?;
        Ok(Self { origin, client })
    }
}

async fn hub_error(error: cmux_cloud_client::Error<cmux_cloud_client::ByteStream>) -> HubError {
    let error = cmux_cloud_client::ApiError::from_api(error).await;
    match error.status {
        Some(status) => HubError::Status { status, code: error.code.unwrap_or_default() },
        None => HubError::Unreachable("no answer".into()),
    }
}

impl Hub for PersonHub {
    fn origin(&self) -> &str {
        &self.origin
    }

    fn mint<'a>(&'a self, label: Option<&'a str>) -> BoxFut<'a, Result<Minted, HubError>> {
        Box::pin(async move {
            let mut body = json!({"ttlSeconds": TOKEN_TTL_SECS});
            if let Some(label) = label {
                body.set("label", json!(label));
            }
            let body: cmux_cloud_client::types::JoinTokenMint = serde_json::from_value(body)
                .map_err(|_| HubError::Unreachable("bad mint body".into()))?;
            let minted = match self.client.machine_join_mint(&body).await {
                Ok(answer) => serde_json::to_value(answer.into_inner()).unwrap_or(Value::Null),
                Err(error) => return Err(hub_error(error).await),
            };
            let text = |key: &str| minted.get(key).and_then(Value::as_str).map(str::to_owned);
            let token = text("token")
                .and_then(|t| super::cloud_join::parse_token_text(&t).ok())
                .ok_or_else(|| HubError::Status { status: 502, code: "token.malformed".into() })?;
            let join_token_id = text("joinTokenId")
                .ok_or_else(|| HubError::Status { status: 502, code: "token.unnamed".into() })?;
            Ok(Minted { token: Zeroizing::new(token), join_token_id })
        })
    }

    fn machines(&self) -> BoxFut<'_, Result<Vec<Row>, HubError>> {
        Box::pin(async move {
            let body = match self.client.machine_join_list().await {
                Ok(answer) => serde_json::to_value(answer.into_inner()).unwrap_or(Value::Null),
                Err(error) => return Err(hub_error(error).await),
            };
            Ok(rows(&body))
        })
    }

    fn revoke<'a>(&'a self, machine_id: &'a str) -> BoxFut<'a, Result<(), HubError>> {
        Box::pin(async move {
            let id = machine_id.parse().map_err(|_| HubError::Status {
                status: 400,
                code: "machine.malformed_id".into(),
            })?;
            match self.client.machine_join_revoke(&id).await {
                Ok(_) => Ok(()),
                Err(error) => Err(hub_error(error).await),
            }
        })
    }

    fn remember(&self, entry: ledger::Entry) {
        if let Err(error) = ledger::remember(&ledger::path(), entry) {
            tracing::warn!("could not record the join token's machine: {error}");
        }
    }

    fn remembered(&self, join_token_id: &str) -> Option<ledger::Entry> {
        ledger::find(&ledger::path(), join_token_id)
    }
}

/// The machine list's rows (tolerant of fields it does not know).
pub fn rows(body: &Value) -> Vec<Row> {
    let list = body.get("machines").or_else(|| body.get("credentials")).and_then(Value::as_array);
    list.into_iter()
        .flatten()
        .filter_map(|row| {
            let text = |key: &str| {
                row.get(key).and_then(Value::as_str).filter(|t| !t.is_empty()).map(str::to_owned)
            };
            let machine_id = text("machineId")?;
            let name = text("label")
                .or_else(|| text("name"))
                .or_else(|| text("hostname"))
                .unwrap_or_else(|| machine_id.clone());
            let last_heartbeat_ms = row.get("lastHeartbeat").and_then(|v| match v {
                Value::String(at) => chrono::DateTime::parse_from_rfc3339(at)
                    .ok()
                    .and_then(|at| u64::try_from(at.timestamp_millis()).ok()),
                Value::Number(n) => {
                    n.as_u64().map(|n| if n < 100_000_000_000 { n * 1000 } else { n })
                }
                _ => None,
            });
            Some(Row {
                machine_id,
                name,
                join_token_id: text("joinTokenId"),
                last_heartbeat_ms,
                revoked: row.get("revoked").and_then(Value::as_bool).unwrap_or(false),
                hostname: text("hostname"),
            })
        })
        .collect()
}

/// Runs the join with the real ssh and the hub as the person with `access`.
pub async fn join_as(
    request: &Request,
    access: Zeroizing<String>,
    emit: &mut (dyn FnMut(Progress) + Send),
) -> Outcome {
    match PersonHub::new(request.hub.clone(), &access) {
        Ok(hub) => join(request, &ProcessSsh, &hub, emit).await,
        Err(error) => Outcome {
            ok: false,
            host: request.host.clone(),
            machine: None,
            platform: None,
            seconds: 0,
            replaced: Vec::new(),
            already_joined: false,
            failure: Some(Failure::new(
                Kind::Usage,
                format!("the hub origin is not usable: {error:#}"),
                "pass an https hub origin (or none for the default)",
            )),
        },
    }
}

#[path = "ssh_join_ledger.rs"]
pub mod ledger;

#[cfg(test)]
#[path = "ssh_join_tests.rs"]
mod tests;
