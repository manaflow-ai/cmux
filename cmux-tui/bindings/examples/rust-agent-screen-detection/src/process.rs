//! Foreground process-group discovery and userland agent identification.
//!
//! The process model is adapted from herdr's `src/platform/{linux,macos}.rs`
//! and `src/detect/mod.rs` at commit
//! `7b675f42af35508eab66ac42fe1598628597a893` (Apache-2.0). The strict Pi
//! bundled-launcher suffixes also incorporate herdr commit
//! `b1ff4582e9688f52ffb943cfa8bee4871ae122e4` (Apache-2.0). Package
//! launchers, the Hermes installer, Letta interactivity, Cline's hidden
//! launcher and the agent pid follow herdr `2563803dca97c040beaf3dc3acdcb5a3221b4238`
//! (see `launchers`). The plugin keeps this platform code outside cmux core,
//! adds bounded traversal and precise attached-versus-separate runtime option
//! boundaries, and resolves names through the replaceable manifest set
//! instead of a closed agent enum.

use cmux::ProcessInfoResult;

use crate::manifest::{CompiledManifest, ManifestSet};

mod launchers;
use launchers::{cursor_bundled_agent, known_package_agent, known_package_path_agent};

/// One process in the terminal's foreground process group.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ForegroundProcess {
    pub pid: u32,
    /// Kernel process name, or the platform equivalent.
    pub name: String,
    /// Effective argv[0], when the platform exposes it.
    pub argv0: Option<String>,
    pub argv: Vec<String>,
    pub cmdline: Option<String>,
}

/// The complete process group currently attached to a terminal.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ForegroundJob {
    pub process_group_id: u32,
    pub processes: Vec<ForegroundProcess>,
}

/// Collect the foreground process group for a terminal PTY child.
///
/// This is best effort. The scanner falls back to the generic process fields
/// returned by the daemon when a host denies process inspection.
pub fn foreground_job(child_pid: u32) -> Option<ForegroundJob> {
    if child_pid == 0 {
        return None;
    }
    platform::foreground_job(child_pid)
}

/// Build a one-process job from the public SDK response. This path keeps the
/// plugin usable on hosts without native process-group APIs.
pub fn fallback_job(process: &ProcessInfoResult) -> ForegroundJob {
    let name = process
        .foreground_executable
        .clone()
        .or_else(|| process.executable.clone())
        .or_else(|| process.argv.first().cloned())
        .unwrap_or_default();
    ForegroundJob {
        process_group_id: process.pid,
        processes: vec![ForegroundProcess {
            pid: process.pid,
            name,
            argv0: process.argv.first().cloned(),
            argv: process.argv.clone(),
            cmdline: (!process.argv.is_empty()).then(|| process.argv.join(" ")),
        }],
    }
}

/// Identify an agent in a foreground process group.
///
/// The process-group leader gets first refusal. If it is a shell or runtime,
/// all group members are scored next. This preserves herdr's useful behavior
/// for `node`, Python, shell, cmd, and PowerShell wrappers while keeping the
/// actual supported-agent catalog in user-editable manifests.
pub fn identify_job<'a>(
    manifests: &'a ManifestSet,
    job: &ForegroundJob,
) -> Option<(&'a CompiledManifest, String)> {
    identify_job_process(manifests, job).map(|(manifest, candidate, _)| (manifest, candidate))
}

/// Like [`identify_job`], plus the pid of the process that matched. That
/// process need not lead its job (herdr 950d012c), and the scanner uses it to
/// keep a suspended or backgrounded agent's identity.
pub fn identify_job_process<'a>(
    manifests: &'a ManifestSet,
    job: &ForegroundJob,
) -> Option<(&'a CompiledManifest, String, u32)> {
    if let Some(leader) = job.processes.iter().find(|process| process.pid == job.process_group_id)
        && let Some((manifest, candidate)) = identify_process(manifests, leader)
    {
        return Some((manifest, candidate, leader.pid));
    }
    let mut best: Option<(u8, &'a CompiledManifest, String, u32)> = None;
    for process in &job.processes {
        let Some((manifest, candidate)) = identify_process(manifests, process) else {
            continue;
        };
        match best {
            Some((best_priority, ..)) if best_priority >= process_priority(process) => {}
            _ => best = Some((process_priority(process), manifest, candidate, process.pid)),
        }
    }
    best.map(|(_, manifest, candidate, pid)| (manifest, candidate, pid))
}

/// Identify a process using the same foreground-group and public-process
/// fallback used by the scanner. Keeping this order shared with diagnostics
/// prevents an explain result from disagreeing with the state publisher.
pub fn identify_job_with_process_fallback<'a>(
    manifests: &'a ManifestSet,
    job: &ForegroundJob,
    process: &ProcessInfoResult,
) -> Option<(&'a CompiledManifest, String)> {
    identify_job(manifests, job).or_else(|| identify_process_info(manifests, process))
}

/// Identify the public process response alone. It is the fallback for hosts
/// without native process-group APIs and is never authoritative.
pub fn identify_process_info<'a>(
    manifests: &'a ManifestSet,
    process: &ProcessInfoResult,
) -> Option<(&'a CompiledManifest, String)> {
    process
        .foreground_executable
        .as_deref()
        .or(process.executable.as_deref())
        .or_else(|| process.argv.first().map(String::as_str))
        .and_then(|name| manifests.identify(name).map(|manifest| (manifest, name.to_string())))
}

fn identify_process<'a>(
    manifests: &'a ManifestSet,
    process: &ForegroundProcess,
) -> Option<(&'a CompiledManifest, String)> {
    identify_process_with_hint(manifests, process, platform::agent_hint)
}

fn identify_process_with_hint<'a, Hint>(
    manifests: &'a ManifestSet,
    process: &ForegroundProcess,
    mut hint: Hint,
) -> Option<(&'a CompiledManifest, String)>
where
    Hint: FnMut(u32) -> Option<String>,
{
    // Executable and wrapper evidence is already present in the process
    // record. Try it first so ordinary agent scans do not read /proc or the
    // macOS process environment. The explicit hint remains a fallback for a
    // VM, sandbox, or other wrapper that hides the real executable.
    let found = process_candidates(process)
        .into_iter()
        .find_map(|candidate| manifests.identify(&candidate).map(|manifest| (manifest, candidate)))
        // An explicit process hint is optional and stays inside the plugin.
        // The replaceable manifest set validates it before it becomes an
        // adapter identity.
        .or_else(|| {
            hint(process.pid)
                .and_then(|hint| manifests.identify(&hint).map(|manifest| (manifest, hint)))
        });
    // Letta's one-shot, server and subcommand modes are not agent sessions
    // (herdr fc1cb77f).
    found.filter(|(manifest, _)| {
        manifest.id() != "letta" || launchers::letta_is_interactive(process)
    })
}

fn process_candidates(process: &ForegroundProcess) -> Vec<String> {
    let mut candidates = Vec::new();
    let mut push = |candidate: String| {
        if !candidate.is_empty() && !candidates.iter().any(|existing| existing == &candidate) {
            candidates.push(candidate);
        }
    };

    if let Some(argv0) = process.argv0.as_deref() {
        push(argv0.to_string());
    }
    push(process.name.clone());
    if let Some(argv0) = process.argv.first() {
        push(argv0.clone());
    }

    let effective = process
        .argv0
        .as_deref()
        .or_else(|| process.argv.first().map(String::as_str))
        .unwrap_or(&process.name);
    let runtime = normalized_name(effective);

    // Some package launchers keep a generic `node` process name and use a
    // non-agent script basename. Match only the known executable path shape,
    // so a package's build or postinstall script cannot look like a live
    // agent. This is the same false-positive guard herdr uses for these
    // launchers, expressed in terms of replaceable manifest ids.
    if let Some(candidate) = known_package_agent(effective, &process.argv) {
        push(candidate);
    }
    if let Some(candidate) = cursor_bundled_agent(&process.argv) {
        push(candidate);
    }

    if is_runtime_or_shell(&runtime)
        && let Some(candidate) = wrapped_agent_from_argv(&runtime, &process.argv)
    {
        push(candidate);
    }

    // A runtime can expose a generic argv[0] while its script path names the
    // agent. Inspect path components, but never inspect arbitrary eval text.
    // Only a runtime's script is an identity; another program's arguments
    // are data (herdr f3cbe03f rejects `other /path/to/cline`).
    if is_runtime_or_shell(&runtime) && !is_eval_invocation(&runtime, &process.argv) {
        let arguments = runtime_path_arguments(&runtime, &process.argv);
        for argument in arguments {
            for candidate in path_candidates(argument) {
                push(candidate);
            }
        }
    }
    // Herdr's final fallback inspects only argv[0] from a raw command line.
    // Scanning every token lets ordinary option values or model text claim an
    // agent identity. Use this path only when the structured argv is absent.
    if process.argv.is_empty()
        && let Some(cmdline) = process.cmdline.as_deref()
        && !is_eval_invocation(&runtime, &process.argv)
        && !is_runtime_or_shell(&runtime)
        && let Some(token) = shell_words(cmdline).into_iter().next()
    {
        for candidate in path_candidates(&token) {
            push(candidate);
        }
    }

    launchers::with_hidden_launcher_aliases(candidates)
}

fn process_priority(process: &ForegroundProcess) -> u8 {
    let effective = process
        .argv0
        .as_deref()
        .or_else(|| process.argv.first().map(String::as_str))
        .unwrap_or(&process.name);
    let effective = normalized_name(effective);
    let kernel_name = normalized_name(&process.name);
    if effective != kernel_name {
        3
    } else if !is_runtime_or_shell(&effective) {
        2
    } else {
        1
    }
}

fn wrapped_agent_from_argv(runtime: &str, argv: &[String]) -> Option<String> {
    match runtime {
        "node" | "bun" => {
            if is_eval_invocation(runtime, argv) {
                None
            } else {
                runtime_path_arguments(runtime, argv)
                    .into_iter()
                    .find_map(|argument| path_candidates(argument).into_iter().next())
            }
        }
        name if is_python_runtime(name) => {
            // Hermes' installer runs `python -I -c <bootstrap>` (herdr e35f3937).
            if let Some(agent) = launchers::hermes_installer_agent(argv) {
                Some(agent)
            } else if is_eval_invocation(runtime, argv) {
                None
            } else {
                runtime_path_arguments(runtime, argv)
                    .into_iter()
                    .find_map(|argument| path_candidates(argument).into_iter().next())
            }
        }
        "sh" | "bash" | "zsh" | "fish" => shell_wrapped_agent(runtime, argv),
        "cmd" => windows_cmd_agent(argv),
        "powershell" | "pwsh" => powershell_agent(argv),
        // tmux is a process-group transport, not an agent wrapper. Its
        // children are inspected separately when the platform exposes them.
        "tmux" => None,
        _ => None,
    }
}

fn shell_wrapped_agent(runtime: &str, argv: &[String]) -> Option<String> {
    let mut index = 1;
    let mut reads_stdin = false;
    while let Some(argument) = argv.get(index) {
        // Shell option letters are case-sensitive. Keep the raw spelling for
        // this parser; `normalized_flag` is reserved for the case-insensitive
        // Windows and PowerShell wrappers below.
        let flag = shell_flag(argument);
        if flag == "--" {
            if reads_stdin {
                return None;
            }
            return argv
                .get(index + 1)
                .and_then(|script| path_candidates(script).into_iter().next());
        }
        if let Some(command) =
            shell_command_words(runtime, flag, argv.get(index + 1).map(String::as_str))
        {
            return command_first_path_candidate(&command);
        }
        if flag.starts_with('-') || (runtime == "zsh" && flag.starts_with('+')) {
            if shell_option_exits(runtime, flag) {
                return None;
            }
            if shell_option_takes_value(runtime, flag) {
                index = index.saturating_add(2);
                continue;
            }
            if shell_option_has_attached_value(runtime, flag) {
                // The value is already part of this option. Do not consume
                // the following token, which may be the script.
                index += 1;
                continue;
            }
            if shell_option_reads_stdin(runtime, flag) {
                reads_stdin = true;
                index += 1;
                continue;
            }
            if shell_option_without_value(runtime, flag) {
                index += 1;
                continue;
            }
            // Unknown options may consume the next value. Failing closed is
            // safer than treating that value as an agent executable.
            return None;
        }
        if reads_stdin {
            return None;
        }
        // For `sh /path/to/agent`, the first positional value is the script.
        // Later values are script arguments and must not affect identity.
        return path_candidates(argument).into_iter().next();
    }
    None
}

fn windows_cmd_agent(argv: &[String]) -> Option<String> {
    let mut index = 1;
    while let Some(argument) = argv.get(index) {
        match normalized_flag(argument).as_str() {
            "/c" | "/k" => {
                return argv
                    .get(index + 1)
                    .and_then(|command| command_first_path_candidate(&shell_words(command)));
            }
            "/d" | "/s" | "/q" | "/a" | "/u" | "/e:on" | "/e:off" | "/f:on" | "/f:off"
            | "/v:on" | "/v:off" => {}
            _ => {}
        }
        index += 1;
    }
    None
}

fn powershell_agent(argv: &[String]) -> Option<String> {
    let mut index = 1;
    while let Some(argument) = argv.get(index) {
        match normalized_flag(argument).as_str() {
            "-file" | "-f" | "/file" => {
                return argv
                    .get(index + 1)
                    .and_then(|path| path_candidates(path).into_iter().next());
            }
            "-command" | "-c" | "/command" | "/c" => {
                return argv
                    .get(index + 1)
                    .and_then(|command| command_first_path_candidate(&shell_words(command)));
            }
            "-encodedcommand" | "-enc" | "/encodedcommand" | "/enc" => return None,
            // These options consume the next token. Without advancing over
            // that value, a path or word equal to an agent id can be treated
            // as the executable even though PowerShell is only configuring
            // itself.
            "-configurationname" | "-executionpolicy" | "-outputformat" | "-psconsolefile"
            | "-version" | "-windowstyle" | "-workingdirectory" => {
                index = index.saturating_add(1);
            }
            _ if argument.starts_with('-') || argument.starts_with('/') => {}
            _ => return path_candidates(argument).into_iter().next(),
        }
        index += 1;
    }
    None
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum ShellOptionKind {
    Safe,
    NoScript,
    TakesValue,
    NoExecute,
    Exits,
}

/// Return shell words for a command-mode flag. The command syntax is kept
/// runtime-specific because a generic "any cluster ending in c" rule treats
/// value-taking options such as bash `-o` as command mode. Fish accepts both
/// the separate `--command` argument and the inline `--command=...` form.
fn shell_command_words(runtime: &str, flag: &str, next: Option<&str>) -> Option<Vec<String>> {
    if runtime == "fish" {
        if flag == "--command" {
            return Some(next.map_or_else(Vec::new, shell_words));
        }
        if let Some(command) = flag.strip_prefix("--command=") {
            return Some(shell_words(command));
        }
    }
    if is_shell_command_flag(runtime, flag) {
        return Some(next.map_or_else(Vec::new, shell_words));
    }
    None
}

fn is_shell_command_flag(runtime: &str, flag: &str) -> bool {
    if flag == "-c" {
        return matches!(runtime, "bash" | "sh" | "zsh" | "fish");
    }

    let Some(characters) = flag.strip_prefix('-').map(str::chars) else {
        return false;
    };
    // Bash, sh, and zsh accept `c` anywhere in a short-option cluster. Fish
    // requires it to be the final short option. Value-taking, no-execute,
    // exit-only, and unknown options remain invalid on either side of `c`.
    let mut characters = characters.peekable();
    let mut command_count = 0;
    while let Some(character) = characters.next() {
        if character == 'c' {
            command_count += 1;
            if runtime == "fish" && characters.peek().is_some() {
                return false;
            }
            continue;
        }
        if !matches!(
            shell_short_option_kind(runtime, character),
            Some(ShellOptionKind::Safe | ShellOptionKind::NoScript)
        ) {
            return false;
        }
    }
    command_count == 1
}

fn shell_short_option_kind(runtime: &str, option: char) -> Option<ShellOptionKind> {
    match runtime {
        // Bash documents these as invocation flags. `-n` and `-D` prevent a
        // command from running, while `-o` and `-O` consume an option name.
        "bash" => match option {
            'a' | 'b' | 'e' | 'f' | 'h' | 'i' | 'k' | 'l' | 'm' | 'p' | 'r' | 'u' | 'v' | 'x'
            | 'B' | 'C' | 'E' | 'H' | 'P' | 'T' => Some(ShellOptionKind::Safe),
            's' | 't' => Some(ShellOptionKind::NoScript),
            'n' => Some(ShellOptionKind::NoExecute),
            'D' => Some(ShellOptionKind::Exits),
            'o' | 'O' => Some(ShellOptionKind::TakesValue),
            _ => None,
        },
        // Keep the POSIX/common shell switches here. Different `sh`
        // implementations add flags, so unknown switches fail closed.
        "sh" => match option {
            'a' | 'b' | 'e' | 'f' | 'h' | 'i' | 'k' | 'l' | 'm' | 'p' | 'r' | 'u' | 'v' | 'x' => {
                Some(ShellOptionKind::Safe)
            }
            's' | 't' => Some(ShellOptionKind::NoScript),
            'n' => Some(ShellOptionKind::NoExecute),
            'o' => Some(ShellOptionKind::TakesValue),
            _ => None,
        },
        // zsh exposes a larger set of single-letter option aliases. These
        // are all non-consuming options; `-n` is noexec, `-o` takes a name,
        // and `-b` is the documented end-options switch.
        "zsh" => match option {
            'J' | 'N' | 'T' | 'w' | 'E' | 'D' | '9' | 'X' | 'Y' | 'S' | '4' | 'I' | '8' | 'G'
            | 'P' | 'h' | 'g' | 'a' | '0' | 'O' | '7' | 'k' | 'U' | 'Q' | '1' | 'H' | 'L' | 'W'
            | '6' | 'R' | 'm' | '5' | 'e' | 'v' | 'x' | 'y' | 'i' | 'l' | 'p' | 'r' | 'M' | 'Z'
            | 'b' | 'd' | 'f' => Some(ShellOptionKind::Safe),
            's' | 't' => Some(ShellOptionKind::NoScript),
            'n' => Some(ShellOptionKind::NoExecute),
            'o' => Some(ShellOptionKind::TakesValue),
            _ => None,
        },
        // Fish's short options follow its command-line synopsis. `-h` and
        // `-v` exit, while `-C`, `-d`, `-f`, `-o`, and `-p` consume values.
        "fish" => match option {
            'i' | 'l' | 'N' | 'P' => Some(ShellOptionKind::Safe),
            'n' => Some(ShellOptionKind::NoExecute),
            'h' | 'v' => Some(ShellOptionKind::Exits),
            'C' | 'd' | 'f' | 'o' | 'p' => Some(ShellOptionKind::TakesValue),
            _ => None,
        },
        _ => None,
    }
}

fn shell_option_exits(runtime: &str, flag: &str) -> bool {
    match runtime {
        "bash" => matches!(
            flag,
            "-D" | "--dump-po-strings"
                | "--dump-strings"
                | "--help"
                | "--pretty-print"
                | "--version"
        ),
        "sh" => matches!(
            flag,
            "--dump-po-strings" | "--dump-strings" | "--help" | "--pretty-print" | "--version"
        ),
        "zsh" => matches!(flag, "--help" | "--version"),
        "fish" => matches!(flag, "-h" | "-v" | "--help" | "--print-debug-categories" | "--version"),
        _ => false,
    }
}

fn shell_option_takes_value(runtime: &str, flag: &str) -> bool {
    match runtime {
        "bash" => {
            // This predicate means that the option consumes the *next*
            // argv element. Attached spellings are accepted only below when
            // the runtime documents them.
            matches!(flag, "-o" | "-O" | "--rcfile" | "--init-file")
        }
        "zsh" => matches!(flag, "-o" | "+o"),
        "fish" => {
            matches!(flag, "-C" | "-d" | "-f" | "-o" | "-p")
                || matches!(
                    flag,
                    "--debug"
                        | "--debug-output"
                        | "--features"
                        | "--init-command"
                        | "--profile"
                        | "--profile-startup"
                )
        }
        "sh" => flag == "-o",
        _ => false,
    }
}

fn shell_option_has_attached_value(runtime: &str, flag: &str) -> bool {
    match runtime {
        "fish" => [
            "--debug",
            "--debug-output",
            "--features",
            "--init-command",
            "--profile",
            "--profile-startup",
        ]
        .iter()
        .any(|option| long_option_with_attached_value(flag, option)),
        _ => false,
    }
}

/// Return true for a short-option cluster that selects stdin as the shell's
/// command source. These options do not consume a following argument, but a
/// following positional token becomes `$0` or a shell argument rather than a
/// script. A later `-c` remains valid, so the caller tracks this state instead
/// of treating `-s` or `-t` as an unknown option.
fn shell_option_reads_stdin(runtime: &str, flag: &str) -> bool {
    let Some(characters) = flag.strip_prefix('-').filter(|value| !value.is_empty()) else {
        return false;
    };
    let mut saw_stdin_mode = false;
    for character in characters.chars() {
        match shell_short_option_kind(runtime, character) {
            Some(ShellOptionKind::Safe) => {}
            Some(ShellOptionKind::NoScript) => saw_stdin_mode = true,
            _ => return false,
        }
    }
    saw_stdin_mode
}

fn long_option_with_attached_value(flag: &str, option: &str) -> bool {
    flag.strip_prefix(option).is_some_and(|value| value.starts_with('='))
}

fn shell_option_without_value(runtime: &str, flag: &str) -> bool {
    if flag.starts_with("--") {
        return match runtime {
            "bash" => matches!(
                flag,
                "--login"
                    | "--noprofile"
                    | "--norc"
                    | "--posix"
                    | "--restricted"
                    | "--verbose"
                    | "--xtrace"
                    | "--noediting"
                    | "--help"
                    | "--version"
            ),
            "zsh" => matches!(flag, "--login" | "--no-rcs" | "--sh" | "--emacs" | "--vi"),
            "fish" => matches!(
                flag,
                "--interactive"
                    | "--login"
                    | "--no-config"
                    | "--no-editing"
                    | "--private"
                    | "--print-rusage-self"
                    | "--help"
                    | "--version"
            ),
            "sh" => matches!(flag, "--login" | "--posix" | "--restricted" | "--verbose"),
            _ => false,
        };
    }

    // These are the runtime-specific short shell switches that do not
    // consume the next argument. Value-taking, no-exec, exit-only, and
    // unknown switches deliberately fail closed.
    let Some(characters) = flag.strip_prefix('-').filter(|value| !value.is_empty()) else {
        return false;
    };
    characters.chars().all(|character| {
        matches!(shell_short_option_kind(runtime, character), Some(ShellOptionKind::Safe))
    })
}

/// Return only the executable token from a shell command. Scanning every
/// token makes `echo codex` look like a codex process even though codex is
/// merely text. Wrapper keywords used by common shells are skipped.
fn command_first_path_candidate(tokens: &[String]) -> Option<String> {
    for token in tokens {
        let token = token.trim();
        if token.is_empty() {
            continue;
        }
        if matches!(token, "exec" | "command" | "env" | "sudo" | "call" | "." | "&") {
            continue;
        }
        if token == "&&" || token == "||" || token == ";" {
            break;
        }
        if token.contains('=')
            && !token.bytes().next().is_some_and(|byte| byte == b'/' || byte == b'\\')
        {
            continue;
        }
        return path_candidates(token).into_iter().next();
    }
    None
}

/// Return executable/script arguments for a runtime without treating option
/// values or arbitrary model text as a process name.
fn runtime_path_arguments<'a>(runtime: &str, argv: &'a [String]) -> Vec<&'a str> {
    // Command interpreters have their own grammar. Their positional
    // arguments can be commands, configuration values, or arbitrary text,
    // so only the dedicated wrapper parsers above may identify an agent.
    if matches!(runtime, "sh" | "bash" | "zsh" | "fish" | "cmd" | "powershell" | "pwsh" | "tmux") {
        return Vec::new();
    }
    let mut result = Vec::new();
    let mut index = 1;
    while let Some(argument) = argv.get(index) {
        if argument == "--" {
            if let Some(next) = argv.get(index + 1) {
                result.push(next.as_str());
            }
            break;
        }
        if is_eval_flag(runtime, argument) {
            break;
        }
        if runtime_option_exits(runtime, argument) {
            // Python exits after printing help or its version. Any later
            // token is command-line data, never an executable script.
            break;
        }
        if runtime_option_has_unsupported_attached_value(runtime, argument) {
            // An unknown or unsupported `--name=value` spelling may be
            // rejected by the runtime. Do not consume the next token as its
            // value, because that could turn a later mode flag and command
            // text into a false agent script.
            return Vec::new();
        }
        if is_python_runtime(runtime) && runtime_flag_matches(argument, "-m") {
            // Python module mode consumes the following token as a module
            // name. Remaining tokens are module arguments, not executables.
            break;
        }
        if argument.starts_with('-') {
            if runtime_option_takes_value(runtime, argument) {
                index += 1;
            }
            index += 1;
            continue;
        }
        result.push(argument.as_str());
        break;
    }
    result
}

fn is_eval_flag(runtime: &str, argument: &str) -> bool {
    match runtime {
        "node" | "bun" => ["-e", "--eval", "-p", "--print"]
            .iter()
            .any(|flag| runtime_flag_matches(argument, flag)),
        name if is_python_runtime(name) => runtime_flag_matches(argument, "-c"),
        _ => false,
    }
}

/// Match a runtime mode flag in either its separate-argument form or its
/// attached short/long value form. This follows herdr's conservative parser:
/// an attached short value is treated as script text, never as a later path.
fn runtime_flag_matches(argument: &str, flag: &str) -> bool {
    argument == flag
        || (flag.starts_with('-')
            && !flag.starts_with("--")
            && argument.starts_with(flag)
            && argument.len() > flag.len())
        || (flag.starts_with("--")
            && argument.strip_prefix(flag).is_some_and(|rest| rest.starts_with('=')))
}

fn runtime_option_takes_value(runtime: &str, argument: &str) -> bool {
    match runtime {
        "node" | "bun" => matches!(
            argument,
            "-r" | "--require"
                | "--loader"
                | "--import"
                | "--experimental-loader"
                | "--inspect-port"
        ),
        name if is_python_runtime(name) => {
            // `-S` is a boolean site-import switch. `-L` and `-o` are kept
            // for alternate Python runtimes that document those options.
            // This predicate only describes options that consume the next
            // argv element. Unsupported attached long options are handled
            // separately so they cannot skip a later mode flag.
            matches!(argument, "-m" | "-W" | "-X" | "-L" | "-o" | "--check-hash-based-pycs")
        }
        _ => false,
    }
}

/// Return true when a runtime option uses an attached long value that this
/// parser cannot prove is valid. Python's documented long options use a
/// separate value token, so fail closed for every `--name=value` spelling.
fn runtime_option_has_unsupported_attached_value(runtime: &str, argument: &str) -> bool {
    is_python_runtime(runtime) && argument.starts_with("--") && argument.contains('=')
}

fn runtime_option_exits(runtime: &str, argument: &str) -> bool {
    match runtime {
        name if is_python_runtime(name) => matches!(
            argument,
            // CPython documents `-?` as an alias for `-h` and `-VV` as the
            // verbose form of `-V`; both terminate before a script path.
            "-h" | "-?"
                | "-V"
                | "-VV"
                | "--help"
                | "--help-env"
                | "--help-xoptions"
                | "--help-all"
                | "--version"
        ),
        _ => false,
    }
}

fn is_eval_invocation(runtime: &str, argv: &[String]) -> bool {
    let mut index = 1;
    while let Some(argument) = argv.get(index) {
        if argument == "--" {
            return false;
        }
        if is_eval_flag(runtime, argument) {
            return true;
        }
        if is_python_runtime(runtime) && runtime_flag_matches(argument, "-m") {
            return false;
        }
        if argument.starts_with('-') {
            if runtime_option_takes_value(runtime, argument) {
                index += 1;
            }
            index += 1;
            continue;
        }
        // The first positional argument is the script/module entrypoint. Any
        // later flags belong to that program and cannot change the runtime
        // invocation mode.
        break;
    }
    false
}

fn path_candidates(token: &str) -> Vec<String> {
    let token = token.trim_matches(|character| matches!(character, '\'' | '"' | '`'));
    if token.is_empty() || token.starts_with('-') {
        return Vec::new();
    }
    let mut candidates = Vec::new();
    if let Some(candidate) = known_package_path_agent(token) {
        candidates.push(candidate);
    }
    let basename = token.rsplit(['/', '\\']).find(|part| !part.is_empty()).unwrap_or(token);
    push_path_candidate(&mut candidates, basename);

    let components =
        token.split(['/', '\\']).filter(|component| !component.is_empty()).collect::<Vec<_>>();
    if let Some(node_modules) =
        components.iter().rposition(|component| *component == "node_modules")
    {
        // Only package names immediately below node_modules are inspected.
        // This avoids treating an arbitrary directory named `codex` as an
        // agent while retaining npm and pnpm launcher paths.
        if let Some(package) = components.get(node_modules + 1) {
            let package = package.trim_start_matches('@');
            let package_is_scoped = components
                .get(node_modules + 1)
                .is_some_and(|component| component.starts_with('@'));
            let package_is_known_launcher = known_package_path_agent(token).is_some();
            if !package_is_known_launcher
                && !package_is_scoped
                && !package.is_empty()
                && !package.contains('.')
            {
                push_path_candidate(&mut candidates, package);
            }
        }
    }
    if let Some(resolved) = canonical_path_basename(token) {
        push_path_candidate(&mut candidates, &resolved);
    }
    // `push_path_candidate` and the local `push` closure preserve the
    // evidence order. Sorting here would let a low-confidence basename beat
    // a package-specific identity, which is a false-positive risk in wrapper
    // processes.
    candidates
}

fn canonical_path_basename(path: &str) -> Option<String> {
    if !path.bytes().any(|byte| byte == b'/' || byte == b'\\') || path.len() > 4096 {
        return None;
    }
    std::fs::canonicalize(path)
        .ok()
        .and_then(|resolved| resolved.file_name().and_then(|name| name.to_str()).map(str::to_owned))
}

fn push_path_candidate(candidates: &mut Vec<String>, value: &str) {
    let mut value = value.to_string();
    for suffix in [".exe", ".cmd", ".bat", ".ps1", ".js", ".py"] {
        if value.to_ascii_lowercase().ends_with(suffix) {
            value.truncate(value.len() - suffix.len());
            break;
        }
    }
    // Script launchers often use a stable `<agent>-code` or `<agent>-cli`
    // filename. Accept the first component only for these explicit suffixes.
    let mut aliases = Vec::new();
    for suffix in ["-code", "-cli", "-coding-agent"] {
        if let Some(prefix) = value.strip_suffix(suffix)
            && !prefix.is_empty()
        {
            aliases.push(prefix.to_string());
        }
    }
    if !value.is_empty() {
        candidates.push(value);
    }
    candidates.extend(aliases);
}

fn shell_words(input: &str) -> Vec<String> {
    let mut words = Vec::new();
    let mut current = String::new();
    let mut quote = None;
    let mut escaped = false;
    for character in input.chars() {
        if escaped {
            current.push(character);
            escaped = false;
            continue;
        }
        if character == '\\' && quote != Some('\'') {
            escaped = true;
            continue;
        }
        if let Some(active) = quote {
            if character == active {
                quote = None;
            } else {
                current.push(character);
            }
        } else if matches!(character, '\'' | '"') {
            quote = Some(character);
        } else if character.is_whitespace() {
            if !current.is_empty() {
                words.push(std::mem::take(&mut current));
            }
        } else {
            current.push(character);
        }
    }
    if escaped {
        current.push('\\');
    }
    if !current.is_empty() {
        words.push(current);
    }
    words
}

fn normalized_flag(argument: &str) -> String {
    argument.trim_matches('"').to_ascii_lowercase()
}

fn shell_flag(argument: &str) -> &str {
    argument.trim_matches(|character| matches!(character, '\'' | '"'))
}

fn normalized_name(name: &str) -> String {
    let basename = name.rsplit(['/', '\\']).find(|part| !part.is_empty()).unwrap_or(name);
    let mut normalized = basename.trim_start_matches('-').to_ascii_lowercase();
    for suffix in [".exe", ".cmd", ".bat", ".ps1", ".js", ".py"] {
        if normalized.ends_with(suffix) {
            normalized.truncate(normalized.len() - suffix.len());
            break;
        }
    }
    normalized
}

fn is_runtime_or_shell(name: &str) -> bool {
    is_python_runtime(name)
        || matches!(
            name,
            "sh" | "bash"
                | "zsh"
                | "fish"
                | "tmux"
                | "node"
                | "bun"
                | "cmd"
                | "powershell"
                | "pwsh"
        )
}

fn is_python_runtime(name: &str) -> bool {
    name == "python"
        || name.strip_prefix("python").is_some_and(|version| {
            !version.is_empty()
                && version
                    .split('.')
                    .all(|part| !part.is_empty() && part.bytes().all(|byte| byte.is_ascii_digit()))
        })
}

/// Parse the optional process identity hints used by herdr-compatible agent
/// launchers. `CMUX_AGENT` is the native name; `HERDR_AGENT` keeps existing
/// integrations working. The value is still checked against the active
/// manifest set by `identify_process`.
fn parse_agent_env_hint(environ: &[u8]) -> Option<String> {
    let mut herdr_hint = None;
    for record in environ.split(|byte| *byte == 0) {
        let Some(separator) = record.iter().position(|byte| *byte == b'=') else {
            continue;
        };
        let (key, value) = record.split_at(separator);
        let value = &value[1..];
        let is_cmux = key == b"CMUX_AGENT";
        let is_herdr = key == b"HERDR_AGENT";
        if !is_cmux && !is_herdr {
            continue;
        }
        let Ok(value) = std::str::from_utf8(value) else {
            continue;
        };
        let value = value.trim();
        if value.is_empty() || value.len() > 64 || value.bytes().any(|byte| byte.is_ascii_control())
        {
            continue;
        }
        if is_cmux {
            return Some(value.to_string());
        }
        herdr_hint = Some(value.to_string());
    }
    herdr_hint
}

#[cfg(target_os = "linux")]
mod platform {
    use super::{ForegroundJob, ForegroundProcess};
    use std::collections::{HashSet, VecDeque};
    use std::fs::File;
    use std::io::Read;
    use std::path::Path;
    use std::sync::OnceLock;

    const PROCESS_DETECTION_ENV: &str = "CMUX_AGENT_PROCESS_DETECTION";
    const HERDR_PROCESS_DETECTION_ENV: &str = "HERDR_PROCESS_DETECTION";
    const CHILD_GROUPS_SCAN_LIMIT: usize = 64;
    const MAX_PROCESS_COUNT: usize = 256;
    const MAX_PROC_FILE_BYTES: usize = 128 * 1024;
    const MAX_THREADS_PER_PROCESS: usize = 256;

    pub(super) fn foreground_job(child_pid: u32) -> Option<ForegroundJob> {
        let process_group_id = match foreground_process_group_id(child_pid) {
            Some(process_group_id) => process_group_id,
            None if process_detection_mode() == ProcessDetectionMode::ChildGroups => {
                child_groups_foreground_process_group(child_pid)?
            }
            None => return None,
        };
        let mut pids = process_tree_pids([child_pid, process_group_id]);
        pids.sort_unstable();
        pids.dedup();
        let processes = pids
            .into_iter()
            .filter_map(|pid| process_for_group(pid, process_group_id))
            .collect::<Vec<_>>();
        (!processes.is_empty()).then_some(ForegroundJob { process_group_id, processes })
    }

    pub(super) fn agent_hint(pid: u32) -> Option<String> {
        if pid == 0 {
            return None;
        }
        let bytes = read_proc_file(format!("/proc/{pid}/environ"), MAX_PROC_FILE_BYTES)?;
        super::parse_agent_env_hint(&bytes)
    }

    fn process_for_group(pid: u32, process_group_id: u32) -> Option<ForegroundProcess> {
        let stat = read_proc_text(format!("/proc/{pid}/stat"))?;
        let (pgrp, name) = parse_process_stat(&stat)?;
        if pgrp != process_group_id {
            return None;
        }
        let argv = process_argv(pid);
        Some(ForegroundProcess {
            pid,
            name,
            argv0: argv.first().cloned(),
            cmdline: (!argv.is_empty()).then(|| argv.join(" ")),
            argv,
        })
    }

    fn foreground_process_group_id(pid: u32) -> Option<u32> {
        let stat = read_proc_text(format!("/proc/{pid}/stat"))?;
        let close = stat.rfind(')')?;
        let fields = stat.get(close + 1..)?.split_whitespace().collect::<Vec<_>>();
        let tpgid = fields.get(5)?.parse::<i32>().ok()?;
        (tpgid > 0).then_some(tpgid as u32)
    }

    #[derive(Debug, Clone, Copy, PartialEq, Eq)]
    enum ProcessDetectionMode {
        Native,
        ChildGroups,
    }

    fn parse_process_detection_mode(value: Option<&str>) -> Result<ProcessDetectionMode, &str> {
        match value {
            None | Some("") | Some("native") => Ok(ProcessDetectionMode::Native),
            Some("child-groups") => Ok(ProcessDetectionMode::ChildGroups),
            Some(value) => Err(value),
        }
    }

    fn process_detection_mode() -> ProcessDetectionMode {
        static MODE: OnceLock<ProcessDetectionMode> = OnceLock::new();
        *MODE.get_or_init(|| {
            let value = std::env::var(PROCESS_DETECTION_ENV)
                .ok()
                .or_else(|| std::env::var(HERDR_PROCESS_DETECTION_ENV).ok());
            parse_process_detection_mode(value.as_deref()).unwrap_or_else(|value| {
                eprintln!(
                    "cmux-agent-screen-detection: unknown process detection mode {value:?}; using native"
                );
                ProcessDetectionMode::Native
            })
        })
    }

    /// Infer a foreground process group when a Linux host does not expose a
    /// controlling terminal foreground group. This mode is opt-in because a
    /// child process can be running in the background and Linux provides no
    /// kernel signal that distinguishes it from the foreground job.
    fn child_groups_foreground_process_group(child_pid: u32) -> Option<u32> {
        let shell_group_id =
            process_pgrp_and_comm(child_pid).map(|(pgrp, _)| pgrp).filter(|pgrp| *pgrp > 0)? as u32;
        child_groups_foreground_process_group_with(
            child_pid,
            shell_group_id,
            task_ids,
            task_children,
            |pid| process_pgrp_and_comm(pid).map(|(pgrp, _)| pgrp),
        )
    }

    fn child_groups_foreground_process_group_with(
        child_pid: u32,
        shell_group_id: u32,
        mut task_ids: impl FnMut(u32) -> Vec<u32>,
        mut task_children: impl FnMut(u32, u32) -> Vec<u32>,
        mut process_group_id: impl FnMut(u32) -> Option<i32>,
    ) -> Option<u32> {
        let mut newest = None;
        let mut scanned = 0usize;
        for tid in task_ids(child_pid) {
            for child in task_children(child_pid, tid) {
                if scanned >= CHILD_GROUPS_SCAN_LIMIT {
                    return None;
                }
                scanned += 1;
                let Some(pgrp) = process_group_id(child) else { continue };
                if pgrp <= 0 || pgrp as u32 == shell_group_id {
                    continue;
                }
                let pgrp = pgrp as u32;
                newest = Some(newest.map_or(pgrp, |current: u32| current.max(pgrp)));
            }
        }
        newest.or(Some(shell_group_id))
    }

    fn process_pgrp_and_comm(pid: u32) -> Option<(i32, String)> {
        let stat = read_proc_text(format!("/proc/{pid}/stat"))?;
        let open = stat.find('(')?;
        let close = stat.rfind(')')?;
        let comm = stat.get(open + 1..close)?.to_string();
        let fields = stat.get(close + 1..)?.split_whitespace().collect::<Vec<_>>();
        let pgrp = fields.get(2)?.parse::<i32>().ok()?;
        Some((pgrp, comm))
    }

    fn parse_process_stat(stat: &str) -> Option<(u32, String)> {
        let open = stat.find('(')?;
        let close = stat.rfind(')')?;
        let name = stat.get(open + 1..close)?.to_string();
        let fields = stat.get(close + 1..)?.split_whitespace().collect::<Vec<_>>();
        let pgrp = fields.get(2)?.parse::<i32>().ok()?;
        (pgrp > 0).then_some((pgrp as u32, name))
    }

    fn process_argv(pid: u32) -> Vec<String> {
        let Some(bytes) = read_proc_file(format!("/proc/{pid}/cmdline"), MAX_PROC_FILE_BYTES)
        else {
            return Vec::new();
        };
        bytes
            .split(|byte| *byte == 0)
            .filter(|part| !part.is_empty())
            .map(|part| String::from_utf8_lossy(part).into_owned())
            .collect()
    }

    fn process_tree_pids(roots: impl IntoIterator<Item = u32>) -> Vec<u32> {
        let mut pending = VecDeque::new();
        let mut visited = HashSet::new();
        for pid in roots {
            if pid > 0 && visited.insert(pid) {
                pending.push_back(pid);
            }
        }
        let mut result = Vec::new();
        while let Some(pid) = pending.pop_front() {
            result.push(pid);
            if result.len() >= MAX_PROCESS_COUNT {
                break;
            }
            for tid in task_ids(pid) {
                for child in task_children(pid, tid) {
                    if child > 0 && visited.insert(child) {
                        pending.push_back(child);
                    }
                }
            }
        }
        result
    }

    fn task_ids(pid: u32) -> Vec<u32> {
        std::fs::read_dir(format!("/proc/{pid}/task"))
            .into_iter()
            .flatten()
            .flatten()
            .take(MAX_THREADS_PER_PROCESS)
            .filter_map(|entry| entry.file_name().to_str()?.parse().ok())
            .collect()
    }

    fn task_children(pid: u32, tid: u32) -> Vec<u32> {
        let Some(text) = read_proc_text(format!("/proc/{pid}/task/{tid}/children")) else {
            return Vec::new();
        };
        text.split_whitespace().filter_map(|child| child.parse().ok()).collect()
    }

    /// Read a proc file with a hard allocation bound. Reading one extra byte
    /// distinguishes an exact-limit file from an oversized file without
    /// allocating the unbounded file first.
    fn read_proc_file(path: impl AsRef<Path>, max_bytes: usize) -> Option<Vec<u8>> {
        let file = File::open(path).ok()?;
        let read_limit = u64::try_from(max_bytes).ok()?.checked_add(1)?;
        let mut bytes = Vec::with_capacity(max_bytes.min(8 * 1024));
        file.take(read_limit).read_to_end(&mut bytes).ok()?;
        (bytes.len() <= max_bytes).then_some(bytes)
    }

    fn read_proc_text(path: impl AsRef<Path>) -> Option<String> {
        String::from_utf8(read_proc_file(path, MAX_PROC_FILE_BYTES)?).ok()
    }
}

#[cfg(target_os = "macos")]
mod platform {
    use super::{ForegroundJob, ForegroundProcess};
    use std::mem::size_of;

    const PROC_PGRP_ONLY: u32 = 2;
    const MAX_PROCESS_COUNT: usize = 256;
    const MAX_PROCARGS_BYTES: usize = 128 * 1024;

    pub(super) fn foreground_job(child_pid: u32) -> Option<ForegroundJob> {
        let process_group_id = foreground_process_group_id(child_pid)?;
        let mut processes = Vec::new();
        for pid in process_group_pids(process_group_id).into_iter().take(MAX_PROCESS_COUNT) {
            let Some(info) = process_bsdinfo(pid) else { continue };
            if info.pbi_pgid != process_group_id {
                continue;
            }
            let Some(name) = comm_from_bsdinfo(&info) else { continue };
            let argv = process_argv(pid);
            processes.push(ForegroundProcess {
                pid,
                name,
                argv0: argv.first().cloned(),
                cmdline: (!argv.is_empty()).then(|| argv.join(" ")),
                argv,
            });
        }
        (!processes.is_empty()).then_some(ForegroundJob { process_group_id, processes })
    }

    pub(super) fn agent_hint(pid: u32) -> Option<String> {
        let buffer = kern_procargs2(pid)?;
        let environment = procargs2_env(&buffer)?;
        super::parse_agent_env_hint(environment)
    }

    fn foreground_process_group_id(pid: u32) -> Option<u32> {
        let mut info = unsafe { std::mem::zeroed::<libc::proc_bsdinfo>() };
        let size = libc::c_int::try_from(size_of::<libc::proc_bsdinfo>()).ok()?;
        let written = unsafe {
            libc::proc_pidinfo(
                pid as libc::c_int,
                libc::PROC_PIDTBSDINFO,
                0,
                (&mut info as *mut libc::proc_bsdinfo).cast(),
                size,
            )
        };
        (written == size && info.e_tpgid > 0).then_some(info.e_tpgid)
    }

    fn process_group_pids(process_group_id: u32) -> Vec<u32> {
        let mut capacity = 32usize;
        for _ in 0..8 {
            let mut pids = vec![0 as libc::pid_t; capacity];
            let Some(bytes) = capacity.checked_mul(size_of::<libc::pid_t>()) else {
                return Vec::new();
            };
            let Ok(bytes) = libc::c_int::try_from(bytes) else {
                return Vec::new();
            };
            let written = unsafe {
                libc::proc_listpids(
                    PROC_PGRP_ONLY,
                    process_group_id,
                    pids.as_mut_ptr().cast(),
                    bytes,
                )
            };
            if written <= 0 {
                return Vec::new();
            }
            let written = written as usize;
            let count = written / size_of::<libc::pid_t>();
            if written < bytes as usize {
                return pids
                    .into_iter()
                    .take(count)
                    .filter_map(|pid| u32::try_from(pid).ok())
                    .filter(|pid| *pid > 0)
                    .collect();
            }
            capacity = capacity.saturating_mul(2);
        }
        Vec::new()
    }

    fn process_bsdinfo(pid: u32) -> Option<libc::proc_bsdinfo> {
        let mut info = unsafe { std::mem::zeroed::<libc::proc_bsdinfo>() };
        let size = libc::c_int::try_from(size_of::<libc::proc_bsdinfo>()).ok()?;
        let written = unsafe {
            libc::proc_pidinfo(
                pid as libc::c_int,
                libc::PROC_PIDTBSDINFO,
                0,
                (&mut info as *mut libc::proc_bsdinfo).cast(),
                size,
            )
        };
        (written == size).then_some(info)
    }

    fn comm_from_bsdinfo(info: &libc::proc_bsdinfo) -> Option<String> {
        let end = info.pbi_comm.iter().position(|byte| *byte == 0).unwrap_or(info.pbi_comm.len());
        (end > 0).then(|| {
            String::from_utf8_lossy(
                &info.pbi_comm[..end].iter().map(|byte| *byte as u8).collect::<Vec<_>>(),
            )
            .into_owned()
        })
    }

    fn process_argv(pid: u32) -> Vec<String> {
        let Some(buffer) = kern_procargs2(pid) else { return Vec::new() };
        procargs2_argv(&buffer)
    }

    fn kern_procargs2(pid: u32) -> Option<Vec<u8>> {
        unsafe {
            let mut mib = [libc::CTL_KERN, libc::KERN_PROCARGS2, pid as libc::c_int];
            let mut size = 0usize;
            if libc::sysctl(
                mib.as_mut_ptr(),
                3,
                std::ptr::null_mut(),
                &mut size,
                std::ptr::null_mut(),
                0,
            ) != 0
                || size == 0
            {
                return None;
            }
            // A hostile or corrupted process can report an unbounded argv
            // size. Keep the plugin's inspection memory bounded; the argv
            // parser already handles a truncated final argument.
            let mut buffer = vec![0u8; size.min(MAX_PROCARGS_BYTES)];
            let mut capacity = buffer.len();
            if libc::sysctl(
                mib.as_mut_ptr(),
                3,
                buffer.as_mut_ptr().cast(),
                &mut capacity,
                std::ptr::null_mut(),
                0,
            ) != 0
            {
                return None;
            }
            buffer.truncate(capacity.min(MAX_PROCARGS_BYTES));
            Some(buffer)
        }
    }

    fn procargs2_argv(buffer: &[u8]) -> Vec<String> {
        if buffer.len() < 4 {
            return Vec::new();
        }
        let argc = i32::from_ne_bytes([buffer[0], buffer[1], buffer[2], buffer[3]]);
        if argc <= 0 {
            return Vec::new();
        }
        let rest = &buffer[4..];
        let Some(exec_end) = rest.iter().position(|byte| *byte == 0) else { return Vec::new() };
        let mut position = exec_end;
        while position < rest.len() && rest[position] == 0 {
            position += 1;
        }
        let mut argv = Vec::new();
        for _ in 0..argc {
            if position >= rest.len() {
                break;
            }
            let end = rest[position..]
                .iter()
                .position(|byte| *byte == 0)
                .map_or(rest.len(), |offset| position + offset);
            if end == position {
                break;
            }
            argv.push(String::from_utf8_lossy(&rest[position..end]).into_owned());
            position = end.saturating_add(1);
        }
        argv
    }

    fn procargs2_env(buffer: &[u8]) -> Option<&[u8]> {
        if buffer.len() < 4 {
            return None;
        }
        let argc = i32::from_ne_bytes([buffer[0], buffer[1], buffer[2], buffer[3]]);
        if argc <= 0 {
            return None;
        }
        let rest = &buffer[4..];
        let exec_end = rest.iter().position(|byte| *byte == 0)?;
        let mut position = exec_end;
        while position < rest.len() && rest[position] == 0 {
            position += 1;
        }
        for _ in 0..argc {
            let end = rest.get(position..)?.iter().position(|byte| *byte == 0)?;
            position = position.checked_add(end)?.checked_add(1)?;
        }
        (position <= rest.len()).then_some(&rest[position..])
    }
}

#[cfg(not(any(target_os = "linux", target_os = "macos")))]
mod platform {
    use super::ForegroundJob;

    pub(super) fn foreground_job(_child_pid: u32) -> Option<ForegroundJob> {
        None
    }

    pub(super) fn agent_hint(_pid: u32) -> Option<String> {
        None
    }
}
