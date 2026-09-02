//! Foreground process-group discovery and userland agent identification.
//!
//! The process model is adapted from herdr's `src/platform/{linux,macos}.rs`
//! and `src/detect/mod.rs` at commit
//! `7b675f42af35508eab66ac42fe1598628597a893` (Apache-2.0). The strict Pi
//! bundled-launcher suffixes also incorporate herdr commit
//! `b1ff4582e9688f52ffb943cfa8bee4871ae122e4` (Apache-2.0). The plugin keeps
//! this platform code outside cmux core, adds bounded traversal, and resolves
//! names through the replaceable manifest set instead of a closed agent enum.

use cmux::ProcessInfoResult;

use crate::manifest::{CompiledManifest, ManifestSet};

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
    if let Some(leader) = job.processes.iter().find(|process| process.pid == job.process_group_id)
        && let Some(found) = identify_process(manifests, leader)
    {
        return Some(found);
    }

    let mut best: Option<(u8, &'a CompiledManifest, String)> = None;
    for process in &job.processes {
        let Some((manifest, candidate)) = identify_process(manifests, process) else {
            continue;
        };
        let priority = process_priority(process);
        match best {
            Some((best_priority, _, _)) if best_priority >= priority => {}
            _ => best = Some((priority, manifest, candidate)),
        }
    }
    best.map(|(_, manifest, candidate)| (manifest, candidate))
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
    if let Some(found) = process_candidates(process)
        .into_iter()
        .find_map(|candidate| manifests.identify(&candidate).map(|manifest| (manifest, candidate)))
    {
        return Some(found);
    }

    // An explicit process hint is optional and stays inside the plugin. The
    // replaceable manifest set validates the value before it becomes an
    // adapter identity.
    hint(process.pid).and_then(|hint| manifests.identify(&hint).map(|manifest| (manifest, hint)))
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
    if !is_eval_invocation(&runtime, &process.argv) {
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

    candidates
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
            if is_eval_invocation(runtime, argv) {
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
    while let Some(argument) = argv.get(index) {
        let flag = normalized_flag(argument);
        if argument == "--" {
            return argv
                .get(index + 1)
                .and_then(|script| path_candidates(script).into_iter().next());
        }
        if is_shell_command_flag(&flag) {
            // A command flag consumes the next argv element as shell text.
            // `None` is also the safe result when the value is missing.
            return argv
                .get(index + 1)
                .and_then(|command| command_first_path_candidate(&shell_words(command)));
        }
        if argument.starts_with('-') || (runtime == "zsh" && argument.starts_with('+')) {
            if shell_option_takes_value(runtime, &flag) {
                index = index.saturating_add(2);
                continue;
            }
            if shell_option_without_value(runtime, &flag) {
                index += 1;
                continue;
            }
            // Unknown options may consume the next value. Failing closed is
            // safer than treating that value as an agent executable.
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

fn is_shell_command_flag(flag: &str) -> bool {
    flag == "-c"
        || flag == "--command"
        || (flag.starts_with('-')
            && flag
                .chars()
                .skip(1)
                .all(|character| matches!(character, 'i' | 'l' | 'o' | 'g' | 'c'))
            && flag.ends_with('c'))
}

fn shell_option_takes_value(runtime: &str, flag: &str) -> bool {
    match runtime {
        "bash" => matches!(flag, "-o" | "-O" | "--rcfile" | "--init-file"),
        "zsh" => matches!(flag, "-o" | "+o" | "--cmd" | "--command"),
        "fish" => {
            matches!(flag, "-C" | "--command" | "--init-command" | "--features" | "--debug-level")
        }
        "sh" => flag == "-o",
        _ => false,
    }
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
            "fish" => matches!(flag, "--no-config" | "--no-editing" | "--help" | "--version"),
            "sh" => matches!(flag, "--login" | "--posix" | "--restricted" | "--verbose"),
            _ => false,
        };
    }

    // These are the portable short shell switches that do not consume the
    // next argument. `-o` and `-O` are deliberately excluded because they
    // take a value in bash, zsh, and POSIX sh.
    let Some(characters) = flag.strip_prefix('-').filter(|value| !value.is_empty()) else {
        return false;
    };
    if characters.chars().any(|character| matches!(character, 'o' | 'c')) {
        return false;
    }
    match runtime {
        "bash" | "zsh" | "sh" => characters.chars().all(|character| {
            matches!(
                character,
                'a' | 'b'
                    | 'e'
                    | 'f'
                    | 'h'
                    | 'i'
                    | 'l'
                    | 'm'
                    | 'n'
                    | 'p'
                    | 'r'
                    | 's'
                    | 't'
                    | 'u'
                    | 'v'
                    | 'x'
            )
        }),
        "fish" => characters
            .chars()
            .all(|character| matches!(character, 'h' | 'i' | 'l' | 'n' | 'p' | 'q' | 'v')),
        _ => false,
    }
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
            matches!(argument, "-m" | "-W" | "-X" | "-S" | "-L" | "-o")
        }
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

fn known_package_agent(effective: &str, argv: &[String]) -> Option<String> {
    let runtime = normalized_name(effective);
    if runtime != "node" && runtime != "bun" {
        return None;
    }
    // A package-shaped path can be script text in an attached eval flag.
    // Check the runtime grammar before applying the path-specific launcher
    // exception, or eval text could claim an agent identity.
    if is_eval_invocation(&runtime, argv) {
        return None;
    }
    argv.get(1).and_then(|script| known_package_path_agent(script))
}

fn known_package_path_agent(path: &str) -> Option<String> {
    let raw_components =
        path.split(['/', '\\']).filter(|component| !component.is_empty()).collect::<Vec<_>>();
    let ends_with = |suffix: &[&str]| {
        raw_components.len() >= suffix.len()
            && raw_components[raw_components.len() - suffix.len()..]
                .iter()
                .zip(suffix)
                .all(|(actual, expected)| actual.eq_ignore_ascii_case(expected))
    };
    // Pi's current Windows package emits either the direct CLI or the
    // bundled CLI entrypoint. Compare raw components here. Normalizing file
    // extensions first would turn `cli.exe` into `cli` and accept an invalid
    // executable as a live agent.
    if ends_with(&["node_modules", "@earendil-works", "pi-coding-agent", "dist", "cli.js"])
        || ends_with(&[
            "node_modules",
            "@earendil-works",
            "pi-coding-agent",
            "dist",
            "bundle",
            "cli.js",
        ])
    {
        return Some("pi".into());
    }

    let components = raw_components.into_iter().map(normalized_name).collect::<Vec<_>>();
    for window in components.windows(5) {
        if window == ["node_modules", "@qwen-code", "qwen-code", "dist", "index"] {
            return Some("qwen".into());
        }
    }
    for window in components.windows(4) {
        if window == ["node_modules", "mastracode", "dist", "cli"] {
            return Some("mastracode".into());
        }
    }
    // pnpm's package exposes opencode through `opencode-ai/bin/opencode`.
    if components.windows(3).any(|window| window == ["opencode-ai", "bin", "opencode"]) {
        return Some("opencode".into());
    }
    None
}

fn cursor_bundled_agent(argv: &[String]) -> Option<String> {
    let runtime = argv.first().map(|value| normalized_name(value))?;
    if runtime != "node" {
        return None;
    }
    let runtime_path = argv.first()?;
    let script_path = argv.get(1)?;
    let (runtime_parent, runtime_name) = path_parent_and_basename(runtime_path)?;
    let (script_parent, script_name) = path_parent_and_basename(script_path)?;
    if !runtime_name.eq_ignore_ascii_case("node.exe")
        || !script_name.eq_ignore_ascii_case("index.js")
        || !runtime_parent.eq_ignore_ascii_case(script_parent)
    {
        return None;
    }
    let mut tail = runtime_parent.rsplit(['/', '\\']).filter(|component| !component.is_empty());
    let (Some(version), Some(versions), Some(package)) = (tail.next(), tail.next(), tail.next())
    else {
        return None;
    };
    (package.eq_ignore_ascii_case("cursor-agent")
        && versions.eq_ignore_ascii_case("versions")
        && !version.is_empty())
    .then(|| "cursor".into())
}

fn path_parent_and_basename(path: &str) -> Option<(&str, &str)> {
    let split = path.rfind(['/', '\\'])?;
    let parent = path[..split].trim_end_matches(['/', '\\']);
    let basename = &path[split + 1..];
    (!parent.is_empty() && !basename.is_empty()).then_some((parent, basename))
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

    #[cfg(test)]
    mod tests {
        use super::*;

        #[test]
        fn proc_file_reader_enforces_the_limit_before_parsing() {
            let path = std::env::temp_dir().join(format!(
                "cmux-agent-screen-detection-proc-read-{}-{}",
                std::process::id(),
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .expect("system clock should be after the Unix epoch")
                    .as_nanos()
            ));
            std::fs::write(&path, b"four").expect("write temporary proc fixture");

            assert_eq!(read_proc_file(&path, 4), Some(b"four".to_vec()));
            assert_eq!(read_proc_file(&path, 3), None);

            std::fs::remove_file(path).expect("remove temporary proc fixture");
        }

        #[test]
        fn process_detection_mode_requires_explicit_child_groups_value() {
            assert_eq!(parse_process_detection_mode(None), Ok(ProcessDetectionMode::Native));
            assert_eq!(
                parse_process_detection_mode(Some("native")),
                Ok(ProcessDetectionMode::Native)
            );
            assert_eq!(
                parse_process_detection_mode(Some("child-groups")),
                Ok(ProcessDetectionMode::ChildGroups)
            );
            assert_eq!(parse_process_detection_mode(Some("guess")), Err("guess"));
        }

        #[test]
        fn child_groups_selects_the_newest_non_shell_group() {
            let group = child_groups_foreground_process_group_with(
                10,
                10,
                |_| vec![10, 11],
                |_, tid| match tid {
                    10 => vec![20, 21],
                    11 => vec![22],
                    _ => Vec::new(),
                },
                |pid| match pid {
                    20 => Some(12),
                    21 => Some(17),
                    22 => Some(15),
                    _ => None,
                },
            );
            assert_eq!(group, Some(17));
        }

        #[test]
        fn child_groups_fall_back_to_shell_when_no_child_has_a_new_group() {
            let group = child_groups_foreground_process_group_with(
                10,
                10,
                |_| vec![10],
                |_, _| vec![20],
                |_| Some(10),
            );
            assert_eq!(group, Some(10));
        }

        #[test]
        fn child_groups_fail_closed_at_the_scan_limit() {
            let group = child_groups_foreground_process_group_with(
                10,
                10,
                |_| vec![10],
                |_, _| (0..=CHILD_GROUPS_SCAN_LIMIT as u32).collect(),
                |pid| Some(pid as i32),
            );
            assert_eq!(group, None);
        }
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

#[cfg(test)]
mod tests {
    use super::*;

    fn process(pid: u32, name: &str, argv: &[&str]) -> ForegroundProcess {
        ForegroundProcess {
            pid,
            name: name.into(),
            argv0: argv.first().map(|value| (*value).into()),
            argv: argv.iter().map(|value| (*value).into()).collect(),
            cmdline: Some(argv.join(" ")),
        }
    }

    #[test]
    fn direct_manifest_name_is_identified() {
        let job =
            ForegroundJob { process_group_id: 7, processes: vec![process(7, "codex", &["codex"])] };
        let (manifest, _) = identify_job(ManifestSet::bundled(), &job).expect("codex should match");
        assert_eq!(manifest.id(), "codex");
    }

    #[test]
    fn direct_process_identity_does_not_probe_environment_hint() {
        let process = process(7, "codex", &["codex"]);
        let mut probes = 0;
        let (manifest, _) = identify_process_with_hint(ManifestSet::bundled(), &process, |pid| {
            probes += 1;
            assert_eq!(pid, 7);
            Some("claude".into())
        })
        .expect("codex should match");

        assert_eq!(manifest.id(), "codex");
        assert_eq!(probes, 0, "a direct identity must not read process environment");
    }

    #[test]
    fn environment_hint_is_used_when_process_candidates_are_unknown() {
        let process = process(8, "sandbox-wrapper", &["sandbox-wrapper"]);
        let mut probes = 0;
        let (manifest, candidate) =
            identify_process_with_hint(ManifestSet::bundled(), &process, |pid| {
                probes += 1;
                assert_eq!(pid, 8);
                Some("claude".into())
            })
            .expect("the explicit wrapper hint should identify claude");

        assert_eq!(manifest.id(), "claude");
        assert_eq!(candidate, "claude");
        assert_eq!(probes, 1);
    }

    #[test]
    fn node_package_launcher_is_identified_without_matching_eval_text() {
        let job = ForegroundJob {
            process_group_id: 7,
            processes: vec![process(
                7,
                "node",
                &["node", "/tmp/node_modules/@qwen-code/qwen-code/dist/index.js"],
            )],
        };
        let (manifest, _) = identify_job(ManifestSet::bundled(), &job).expect("qwen should match");
        assert_eq!(manifest.id(), "qwen");

        let eval = ForegroundJob {
            process_group_id: 8,
            processes: vec![process(8, "node", &["node", "-e", "console.log('codex')"])],
        };
        assert!(identify_job(ManifestSet::bundled(), &eval).is_none());
    }

    #[test]
    fn known_package_launchers_require_the_real_cli_entrypoint() {
        for (pid, script) in [
            (7, r"C:\Users\user\node_modules\@earendil-works\pi-coding-agent\dist\cli.js"),
            (8, r"C:\Users\user\node_modules\@earendil-works\pi-coding-agent\dist\bundle\cli.js"),
        ] {
            let pi = ForegroundJob {
                process_group_id: pid,
                processes: vec![process(pid, "node.exe", &["node.exe", script])],
            };
            assert_eq!(identify_job(ManifestSet::bundled(), &pi).unwrap().0.id(), "pi");
        }

        for (pid, script) in [
            (9, r"C:\Users\user\node_modules\@earendil-works\pi-coding-agent\scripts\build.js"),
            (
                10,
                r"C:\Users\user\node_modules\@earendil-works\pi-coding-agent\dist\bundle\update.js",
            ),
            (11, r"C:\workspace\dist\bundle\cli.js"),
            (12, r"C:\workspace\node_modules\other-package\dist\bundle\cli.js"),
            (13, r"C:\workspace\node_modules\@earendil-works\pi-coding-agent\dist\cli.exe"),
            (14, r"C:\workspace\node_modules\@earendil-works\pi-coding-agent\dist\cli.js\other.js"),
            (15, r"C:\workspace\node_modules\@earendil-works\pi-coding-agent\dist\bundle\cli.exe"),
            (
                16,
                r"C:\workspace\node_modules\@earendil-works\pi-coding-agent\dist\bundle\cli.js\other.js",
            ),
        ] {
            let build_script = ForegroundJob {
                process_group_id: pid,
                processes: vec![process(pid, "node.exe", &["node.exe", script])],
            };
            assert!(
                identify_job(ManifestSet::bundled(), &build_script).is_none(),
                "script: {script}"
            );
        }
    }

    #[test]
    fn package_identity_keeps_priority_over_path_basename() {
        let candidates = path_candidates("/tmp/node_modules/opencode-ai/bin/opencode");
        assert_eq!(candidates.first().map(String::as_str), Some("opencode"));
    }

    #[test]
    fn cursor_bundled_node_requires_versioned_index_pair() {
        let valid = ForegroundJob {
            process_group_id: 7,
            processes: vec![process(
                7,
                "node.exe",
                &[
                    r"C:\Users\user\AppData\Local\cursor-agent\versions\2026.08.11\node.exe",
                    r"C:\Users\user\AppData\Local\cursor-agent\versions\2026.08.11\index.js",
                ],
            )],
        };
        assert_eq!(identify_job(ManifestSet::bundled(), &valid).unwrap().0.id(), "cursor");

        let postinstall = ForegroundJob {
            process_group_id: 8,
            processes: vec![process(
                8,
                "node.exe",
                &[
                    r"C:\Users\user\AppData\Local\cursor-agent\versions\2026.08.11\node.exe",
                    r"C:\Users\user\AppData\Local\cursor-agent\versions\2026.08.11\scripts\postinstall.js",
                ],
            )],
        };
        assert!(identify_job(ManifestSet::bundled(), &postinstall).is_none());
    }

    #[test]
    fn shell_command_scanning_does_not_match_arguments_as_executables() {
        let plain = ForegroundJob {
            process_group_id: 7,
            processes: vec![process(7, "bash", &["bash", "-lc", "echo codex"])],
        };
        assert!(identify_job(ManifestSet::bundled(), &plain).is_none());

        let exec = ForegroundJob {
            process_group_id: 8,
            processes: vec![process(8, "bash", &["bash", "-lc", "exec codex"])],
        };
        assert_eq!(identify_job(ManifestSet::bundled(), &exec).unwrap().0.id(), "codex");
    }

    #[test]
    fn shell_and_python_wrappers_are_supported() {
        let shell = ForegroundJob {
            process_group_id: 7,
            processes: vec![process(7, "zsh", &["zsh", "-c", "exec claude"])],
        };
        assert_eq!(identify_job(ManifestSet::bundled(), &shell).unwrap().0.id(), "claude");

        let python = ForegroundJob {
            process_group_id: 8,
            processes: vec![process(8, "python3.12", &["python3.12", "/opt/hermes-agent.py"])],
        };
        assert_eq!(identify_job(ManifestSet::bundled(), &python).unwrap().0.id(), "hermes");
    }

    #[test]
    fn shell_escaped_agent_token_is_identified() {
        let shell = ForegroundJob {
            process_group_id: 7,
            processes: vec![process(7, "bash", &["bash", "-lc", r"exec c\odex"])],
        };
        assert_eq!(identify_job(ManifestSet::bundled(), &shell).unwrap().0.id(), "codex");
    }

    #[test]
    fn shell_script_argument_is_identified() {
        let shell = ForegroundJob {
            process_group_id: 7,
            processes: vec![process(7, "sh", &["/bin/sh", "/tmp/test-bin/pi"])],
        };
        assert_eq!(identify_job(ManifestSet::bundled(), &shell).unwrap().0.id(), "pi");
    }

    #[test]
    fn shell_option_values_are_not_treated_as_script_agents() {
        let shell = ForegroundJob {
            process_group_id: 7,
            processes: vec![process(7, "bash", &["bash", "--rcfile", "/tmp/codex"])],
        };
        assert!(identify_job(ManifestSet::bundled(), &shell).is_none());
    }

    #[test]
    fn runtime_option_values_are_not_treated_as_agent_commands() {
        for (name, argv) in [
            ("node", vec!["node", "--experimental-loader", "codex"]),
            ("node", vec!["node", "--inspect-port", "claude"]),
            ("python3.12", vec!["python3.12", "-S", "codex"]),
            ("python3.12", vec!["python3.12", "-o", "claude"]),
            ("python3.12", vec!["python3.12", "-m", "some_module", "codex"]),
        ] {
            let job =
                ForegroundJob { process_group_id: 7, processes: vec![process(7, name, &argv)] };
            assert!(
                identify_job(ManifestSet::bundled(), &job).is_none(),
                "option value must not identify an agent: {argv:?}",
            );
        }
    }

    #[test]
    fn attached_runtime_modes_are_not_treated_as_agent_commands() {
        for (name, argv) in [
            ("node", vec!["node", "-econsole.log('codex')", "claude"]),
            ("bun", vec!["bun", "-pcodex", "claude"]),
            ("python3.12", vec!["python3.12", "-msome_module", "codex"]),
        ] {
            let job =
                ForegroundJob { process_group_id: 7, processes: vec![process(7, name, &argv)] };
            assert!(
                identify_job(ManifestSet::bundled(), &job).is_none(),
                "attached runtime mode must not identify an agent: {argv:?}",
            );
        }
    }

    #[test]
    fn package_path_in_attached_node_eval_is_not_an_agent_identity() {
        let job = ForegroundJob {
            process_group_id: 7,
            processes: vec![process(
                7,
                "node",
                &["node", "-e/tmp/node_modules/@qwen-code/qwen-code/dist/index.js"],
            )],
        };
        assert!(identify_job(ManifestSet::bundled(), &job).is_none());
    }

    #[test]
    fn runtime_flags_after_the_script_do_not_hide_the_script_identity() {
        for (name, argv, expected) in [
            ("node", vec!["node", "/tmp/codex", "--eval"], "codex"),
            ("python3.12", vec!["python3.12", "/tmp/claude", "-c"], "claude"),
            ("node", vec!["node", "--", "/tmp/codex", "--eval"], "codex"),
            ("node", vec!["node", "--require", "preload.js", "/tmp/codex"], "codex"),
        ] {
            let job =
                ForegroundJob { process_group_id: 7, processes: vec![process(7, name, &argv)] };
            assert_eq!(
                identify_job(ManifestSet::bundled(), &job).map(|(manifest, _)| manifest.id()),
                Some(expected),
                "script identity must survive trailing runtime-looking arguments: {argv:?}",
            );
        }
    }

    #[test]
    fn command_line_fallback_only_uses_the_executable_token() {
        let arbitrary_argument = ForegroundJob {
            process_group_id: 31,
            processes: vec![ForegroundProcess {
                pid: 31,
                name: "wrapper".into(),
                argv0: None,
                argv: Vec::new(),
                cmdline: Some("wrapper --message codex".into()),
            }],
        };
        assert!(identify_job(ManifestSet::bundled(), &arbitrary_argument).is_none());

        let missing_argv = ForegroundJob {
            process_group_id: 32,
            processes: vec![ForegroundProcess {
                pid: 32,
                name: "wrapper".into(),
                argv0: None,
                argv: Vec::new(),
                cmdline: Some("/opt/bin/codex --message hello".into()),
            }],
        };
        assert_eq!(identify_job(ManifestSet::bundled(), &missing_argv).unwrap().0.id(), "codex");
    }

    #[test]
    fn tmux_is_transport_and_does_not_scan_its_arguments() {
        let job = ForegroundJob {
            process_group_id: 7,
            processes: vec![process(7, "tmux", &["tmux", "new-session", "codex"])],
        };
        assert!(identify_job(ManifestSet::bundled(), &job).is_none());
        assert!(is_runtime_or_shell("tmux"));
    }

    #[test]
    fn powershell_option_values_are_not_treated_as_agent_commands() {
        let job = ForegroundJob {
            process_group_id: 7,
            processes: vec![process(7, "pwsh", &["pwsh", "-WorkingDirectory", "codex"])],
        };
        assert!(identify_job(ManifestSet::bundled(), &job).is_none());
    }

    #[test]
    fn versioned_muse_binary_is_identified() {
        let job = ForegroundJob {
            process_group_id: 7,
            processes: vec![process(7, "muse-bin-0.2.1", &["muse-bin-0.2.1"])],
        };
        assert_eq!(identify_job(ManifestSet::bundled(), &job).unwrap().0.id(), "muse");
    }

    #[test]
    fn process_identity_hints_prefer_cmux_and_keep_herdr_compatibility() {
        assert_eq!(
            parse_agent_env_hint(b"PATH=/bin\0HERDR_AGENT=claude\0TERM=xterm\0"),
            Some("claude".into())
        );
        assert_eq!(
            parse_agent_env_hint(b"HERDR_AGENT=claude\0CMUX_AGENT=codex\0"),
            Some("codex".into())
        );
        assert_eq!(parse_agent_env_hint(b"HERDR_AGENT=not valid\0"), Some("not valid".into()));
        assert_eq!(parse_agent_env_hint(b"CMUX_AGENT=\0HERDR_AGENT=codex\0"), Some("codex".into()));
        assert_eq!(
            parse_agent_env_hint(b"CMUX_AGENT=codex\0HERDR_AGENT=claude\0"),
            Some("codex".into())
        );
    }

    #[test]
    fn custom_manifest_aliases_remain_userland_extensible() {
        let job = ForegroundJob {
            process_group_id: 7,
            processes: vec![process(7, "node", &["node", "wrapper.js"])],
        };
        let custom = ManifestSet::from_sources(&[ (
            "custom",
            "id = \"custom-agent\"\nversion = \"1\"\naliases = [\"wrapper\"]\n\n[[rules]]\nid = \"idle\"\nstate = \"idle\"\ncontains = [\"ready\"]\n",
        )])
        .unwrap();
        let (manifest, candidate) = identify_job(&custom, &job).expect("custom alias should match");
        assert_eq!(manifest.id(), "custom-agent");
        assert_eq!(candidate, "wrapper");
    }
}
