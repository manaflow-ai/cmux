import CmuxNextActions
import CmuxNextCloud
import Foundation

/// Set Up GitHub on This Machine (`cmux cloud setup-github`): the person's git identity from this
/// Mac, and GitHub for the Cloud machine's git.
///
/// By default through the cmux GitHub App (``CloudGitHubApp``): `cmux github setup` makes the
/// machine's git ask its Cloud agent for a short-lived token scoped to one repo each time, and no
/// GitHub token is stored on the machine. Only when the App or the team's connection is not there
/// (or the machine has no Cloud agent) does the machine sign in itself through GitHub's device flow:
/// it runs its own `gh auth login --web`, GitHub gives it a one-time code, the person approves that
/// code in their own browser, and GitHub hands the machine a token of its own, which stays there.
///
/// No token leaves this Mac either way. The result carries only `ok`, `method`, `fallback_reason`,
/// `user_name`, `user_email`, `gh_status` and, while a sign-in waits, `device_code` and `verification_uri`.
///
/// The command runs through the Cloud API's exec (`POST /api/vm/{id}/exec`). The provider runs a
/// public exec as the machine's work user (uid 1000, `cmux` on current images; root on images older
/// than the work user), the account terminals and agents run as, so `--global` git config and gh's
/// config land in that user's home. The API takes one shell string, so the two values from this Mac
/// are the only caller data in it: ``validated(_:)`` refuses control characters, and
/// ``shellQuote(_:)`` single-quotes each value. One shell parses the string once and nothing parses
/// the values again: they reach `git config` as one argv entry each.
nonisolated enum CloudGitHubSetup {
    /// `git config --global user.name` and `user.email` as this Mac has them; nil when unset.
    struct GitIdentity: Equatable, Sendable {
        var name: String?
        var email: String?
    }

    /// Where gh stands on the machine after the run (`gh_status`).
    enum GitHubStatus: String, Equatable, Sendable {
        /// `cmux github setup` ran: git asks the cmux GitHub App for each repo's token.
        case app
        /// `gh auth status` already passed: nothing was started.
        case loggedIn = "logged_in"
        /// The device flow is waiting for the person to enter `device_code`.
        case pending
        /// The image has no `gh`.
        case missing
        /// The sign-in did not start or printed no code.
        case failed
    }

    /// Whether the git identity reached the machine.
    enum IdentityStatus: String, Equatable, Sendable {
        case set, skipped, failed
    }

    /// What the machine reported.
    struct Outcome: Equatable, Sendable {
        var identity: IdentityStatus
        var gitHub: GitHubStatus
        var deviceCode: String?
        /// The run was asked to use the App, and the machine has no Cloud agent or `cmux github`.
        var appNotOnMachine = false

        /// Nothing failed: the identity was set (or this Mac had none to set), and git uses the App,
        /// or gh is signed in or waits for the person's approval.
        var ok: Bool { identity != .failed && (gitHub == .app || gitHub == .loggedIn || gitHub == .pending) }
    }

    /// Why the machine signs in to GitHub itself instead of using the App (`fallback_reason`).
    enum Fallback: String, Equatable, Sendable {
        /// The team has no usable connection to the App (the token endpoint's `integration.not_found`).
        case notConnected = "not_connected"
        /// This deployment has no App.
        case notConfigured = "not_configured"
        /// The check did not answer.
        case unknown
        /// The machine has no Cloud agent or no `cmux github` (an older image).
        case notOnMachine = "not_on_machine"
    }

    /// Why the run will not ask for the App (nil when the check says it is ready).
    static func reason(_ app: CloudGitHubApp) -> Fallback? {
        switch app {
        case .ready: nil
        case .notConnected: .notConnected
        case .notConfigured: .notConfigured
        case .unknown: .unknown
        }
    }

    /// Nil when git uses the App; else why not (a ready App the machine said it could not use: `notOnMachine`;
    /// a run that never said, such as a failed exec: `unknown`).
    static func fallback(_ app: CloudGitHubApp, _ outcome: Outcome) -> Fallback? {
        guard outcome.gitHub != .app else { return nil }
        return reason(app) ?? (outcome.appNotOnMachine ? .notOnMachine : .unknown)
    }

    /// Where the person enters the code. A constant, never read from the machine: the app opens
    /// only this page, whatever the machine prints.
    static let verificationURI = "https://github.com/login/device"

    /// The exec's own timeout (the Cloud API's `timeoutMs`): the script waits at most 15 s for
    /// gh's code, inside `action.run`'s 40 s result deadline.
    static let timeoutMs = 25_000

    /// The longest value passed on; a real name or address is far shorter.
    static let maxValueLength = 256

    // MARK: Values from this Mac

    /// This Mac's global git identity, as git prints it (unchecked; see ``validated(_:)``).
    static func localIdentity(git: any MarkdownGitRunning = ProcessMarkdownGitRunner(),
                              home: String = NSHomeDirectory()) async -> GitIdentity {
        async let name = git.run(["config", "--global", "--get", "user.name"], in: home)
        async let email = git.run(["config", "--global", "--get", "user.email"], in: home)
        let read: (MarkdownGitOutput?) -> String? = { output in
            guard let output, output.status == 0 else { return nil }
            return output.output
        }
        return GitIdentity(name: read(await name), email: read(await email))
    }

    /// `identity` with each value trimmed (git ends its output with a newline), empty values
    /// dropped, and a refusal for a value with a control character (a newline inside it, a NUL,
    /// an escape) or longer than ``maxValueLength``.
    static func validated(_ identity: GitIdentity) throws -> GitIdentity {
        GitIdentity(name: try validated(identity.name), email: try validated(identity.email))
    }

    static func validated(_ value: String?) throws -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        let control = value.unicodeScalars.contains { $0.properties.generalCategory == .control }
        guard !control, value.count <= maxValueLength else { throw ActionFailure(message: CloudStrings.gitHubIdentityUnsafe) }
        return value
    }

    /// `value` as one POSIX shell word: inside single quotes nothing is special, and each `'` is
    /// closed, escaped and reopened (`'\''`).
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    // MARK: The machine's command

    /// The one exec script. It prints `cmux-git: set|skipped|failed` and then
    /// `cmux-gh: app|logged_in|missing|failed|pending <code>`, and nothing that came from gh except
    /// the code. With `app`, the App's helper first (``appCommand``); the device flow runs only when
    /// the machine cannot use it. A rerun stops the previous sign-in first (``stopPreviousCommand``).
    static func command(_ identity: GitIdentity, app: Bool = false) -> String {
        var lines = [
            "umask 077",
            // The work user's home and the image's tool store, whatever the provider's exec set.
            #"h=$(getent passwd "$(id -un)" 2>/dev/null | cut -d: -f6); [ -n "$h" ] && HOME=$h; export HOME"#,
            #"export PATH="/opt/cmux/current/bin:/usr/local/bin:$PATH""#,
        ]
        lines.append(identityCommand(identity))
        lines += [
            #"proc=/proc; d="$HOME/.cache/cmux"; log="$d/gh-login.log""#,
            #"mkdir -p "$d" || { echo 'cmux-gh: failed'; exit 0; }"#,
            // First, on every path: an earlier sign-in still waiting for its code would otherwise
            // finish later and put gh back as git's helper over the App's.
            stopPreviousCommand,
        ]
        if app { lines.append(appCommand) }
        // A machine already signed in makes gh git's helper again, on every run that does not use the App:
        // an earlier run may have put the App's helper in, and it fails once the App is gone.
        let signedIn = "gh auth setup-git --hostname github.com >/dev/null 2>&1 || { echo 'cmux-gh: failed'; exit 0; }; "
        lines += [
            "if ! command -v gh >/dev/null 2>&1; then echo 'cmux-gh: missing'; exit 0; fi",
            "if gh auth status --hostname github.com >/dev/null 2>&1; then \(signedIn)echo 'cmux-gh: logged_in'; exit 0; fi",
            #"rm -f "$log""#,
            "s=; command -v setsid >/dev/null 2>&1 && s=setsid",
            // Detached from the exec (its own session, when setsid exists) so the sign-in
            // outlives it; git then uses gh as its credential helper.
            #"$s nohup sh -c \#(signInScript) \#(signInMarker) "$d" </dev/null >"$log" 2>&1 &"#,
            readCodeCommand,
        ]
        return lines.joined(separator: "\n")
    }

    /// The App's git helper (`cmux github setup`, which replaces any helper git had for github.com),
    /// when the machine's Cloud agent socket is there to mint its tokens and `cmux` has the verb;
    /// prints `cmux-gh: app`. Else `cmux-app: unavailable` (no agent socket or no `cmux`: an older image)
    /// or `cmux-app: failed` (the helper did not go in), and the device flow follows.
    static let appCommand = CloudGitHubSetup.appCommand(at: agentSocket)

    /// The Cloud agent's socket on the machine, which `cmux github` asks for each token.
    static let agentSocket = "/run/cmux-vm-agent/agent.sock"

    /// A token ask for a repo no team has. Only a working path answers it with the API's
    /// `policy.denied` (the team's connection may not act on that repo): the agent is bound, reaches
    /// the API, and the team has an active GitHub connection. Anything else (`vm.unbound`, an
    /// unreachable or broken agent, `integration.unavailable`, no connection, a token for it) means
    /// the helper would fail every git call, so the device flow runs instead. The ask gets
    /// ``probeSeconds``: a hung agent (the CLI waits up to 240 s for it) is stopped and counts as
    /// unusable too, so the device flow still starts inside ``timeoutMs``. Sets `unusable` to 1 for
    /// any of them.
    static let unboundProbe = [
        #"probe_err=$(mktemp 2>/dev/null || echo "/tmp/cmux-gh-probe.$$")"#,
        #"printf 'protocol=https\nhost=github.com\npath=cmux-setup-probe/none.git\n\n' | cmux github credential get >/dev/null 2>"$probe_err" & probe=$!"#,
        #"j=0; while kill -0 "$probe" 2>/dev/null && [ $j -lt \#(probeSeconds * 4) ]; do sleep 0.25; j=$((j+1)); done"#,
        #"if kill -0 "$probe" 2>/dev/null; then kill "$probe" 2>/dev/null; unusable=1"#,
        #"elif grep -q 'policy\.denied' "$probe_err"; then unusable=; else unusable=1; fi"#,
        #"rm -f "$probe_err""#,
    ].joined(separator: "\n")

    /// The probe's bound, well inside the exec's ``timeoutMs`` with the device flow's 15 s after it.
    static let probeSeconds = 4

    static func appCommand(at socket: String) -> String {
        [
            "if [ -S \(shellQuote(socket)) ] && command -v cmux >/dev/null 2>&1; then",
            unboundProbe,
            "  if [ -n \"$unusable\" ]; then echo 'cmux-app: unavailable'",
            "  elif cmux github setup >/dev/null 2>&1; then echo 'cmux-gh: app'; exit 0",
            "  else echo 'cmux-app: failed'; fi",
            "else",
            "  echo 'cmux-app: unavailable'",
            "fi",
        ].joined(separator: "\n")
    }

    /// Waits up to 15 s for gh's one-time code in `$log` and prints `cmux-gh: pending <code>`, or
    /// `cmux-gh: failed`. Once the code is read the log is unlinked: gh keeps writing to the open
    /// file, but the code no longer sits on the machine's disk for anything else to read. A log
    /// with no code stays, for diagnosing the failed start.
    static let readCodeCommand = [
        "i=0; code=",
        #"while [ $i -lt 60 ]; do code=$(sed -n 's/.*one-time code: \([A-Z0-9][A-Z0-9]*-[A-Z0-9][A-Z0-9]*\).*/\1/p' "$log" 2>/dev/null | head -n 1); [ -n "$code" ] && break; sleep 0.25; i=$((i+1)); done"#,
        #"if [ -n "$code" ]; then rm -f "$log"; echo "cmux-gh: pending $code"; else echo 'cmux-gh: failed'; fi"#,
    ].joined(separator: "\n")

    /// The detached sign-in's `$0`: the stop below signals only a shell whose command line has it.
    static let signInMarker = "cmux-gh-login"

    /// The detached sign-in, run as `sh -c SCRIPT cmux-gh-login DIR`. It records itself in its own
    /// file `DIR/gh-login.<its pid>.pid` (this boot's id, its pid, then gh's pid) and removes that
    /// file when it ends, however it ends, so no file outlives the run it names. Each run removes
    /// only its own file: a stopped run's exit can never take a newer run's record.
    static let signInBody = [
        #"f="$1/gh-login.$$.pid""#,
        #"trap 'rm -f "$f"' EXIT"#,
        "trap 'exit 143' HUP INT TERM",
        #"printf '%s\n%s\n' "$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)" "$$" >"$f""#,
        "gh auth login --hostname github.com --git-protocol https --web --skip-ssh-key & g=$!",
        #"echo "$g" >>"$f""#,
        "wait $g && gh auth setup-git --hostname github.com",
    ].joined(separator: "\n")

    static var signInScript: String { shellQuote(signInBody) }

    /// Stops the sign-ins earlier runs started, from their files in `$d`; `$proc` is the proc
    /// filesystem (`/proc`; a test passes a fake one). A pid is signalled only when all of these
    /// hold, so a stale file (a reboot, a restored snapshot, a reused pid) signals nothing:
    /// - it is a canonical decimal above 1 (never `0`, `1` or a leading zero: in dash
    ///   `kill -TERM -0` is the caller's own group and `-01` every process the user owns);
    /// - the file was written this boot (its first line is this boot's id, and the id is known);
    /// - the process's command line is the detached sign-in shell (``signInMarker``) or
    ///   `gh auth login`.
    /// The shell is signalled as a process group (setsid made it a group leader; without setsid
    /// the group does not exist and only the pid is signalled), gh by its pid.
    static let stopPreviousCommand = [
        #"boot=$(cat "$proc/sys/kernel/random/boot_id" 2>/dev/null)"#,
        #"for f in "$d"/gh-login.*.pid; do"#,
        #"  [ -f "$f" ] || continue"#,
        #"  { read -r b; read -r sp; read -r gp; } <"$f""#,
        #"  if [ -n "$boot" ] && [ "$b" = "$boot" ]; then"#,
        #"    for p in "$sp" "$gp"; do"#,
        #"      case "$p" in ''|*[!0-9]*|0*|1) continue ;; esac"#,
        #"      c=$(tr '\000' ' ' <"$proc/$p/cmdline" 2>/dev/null)"#,
        #"      case "$c" in"#,
        "        *' \(signInMarker) '*) kill -TERM \"-$p\" 2>/dev/null || kill -TERM \"$p\" 2>/dev/null ;;",
        #"        'gh auth login '*|*'/gh auth login '*) kill -TERM "$p" 2>/dev/null ;;"#,
        #"      esac"#,
        #"    done"#,
        #"  fi"#,
        #"  rm -f "$f""#,
        #"done"#,
    ].joined(separator: "\n")

    /// The line that sets the identity and prints `cmux-git: set|skipped|failed`. The values from
    /// this Mac appear only here, each as one single-quoted word.
    static func identityCommand(_ identity: GitIdentity) -> String {
        var sets: [String] = []
        if let name = identity.name { sets.append("git config --global user.name \(shellQuote(name))") }
        if let email = identity.email { sets.append("git config --global user.email \(shellQuote(email))") }
        guard !sets.isEmpty else { return "echo 'cmux-git: skipped'" }
        return "if \(sets.joined(separator: " && ")); then echo 'cmux-git: set'; else echo 'cmux-git: failed'; fi"
    }

    // MARK: Reading the answer

    /// The outcome the script printed. A code is taken only in GitHub's shape (`XXXX-XXXX`,
    /// letters and digits); anything else is `failed`.
    static func parse(exitCode: Int, stdout: String) -> Outcome {
        var identity = IdentityStatus.failed, gitHub = GitHubStatus.failed, code: String?, notOnMachine = false
        for line in stdout.split(whereSeparator: \.isNewline) {
            let words = line.split(separator: " ").map(String.init)
            guard words.count >= 2 else { continue }
            switch words[0] {
            case "cmux-app:": notOnMachine = notOnMachine || words[1] == "unavailable"
            case "cmux-git:": identity = IdentityStatus(rawValue: words[1]) ?? .failed
            case "cmux-gh:":
                gitHub = GitHubStatus(rawValue: words[1]) ?? .failed
                code = gitHub == .pending && words.count == 3 && isDeviceCode(words[2]) ? words[2] : nil
                if gitHub == .pending, code == nil { gitHub = .failed }
            default: continue
            }
        }
        // A run that did not finish says nothing sure about the machine: its fallback reason is unknown.
        guard exitCode == 0 else { return Outcome(identity: identity == .set ? .set : .failed, gitHub: .failed) }
        return Outcome(identity: identity, gitHub: gitHub, deviceCode: code, appNotOnMachine: notOnMachine)
    }

    static func isDeviceCode(_ text: String) -> Bool {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy { part in
            part.count == 4 && part.unicodeScalars.allSatisfy { ("A"..."Z").contains($0) || ("0"..."9").contains($0) }
        }
    }

    /// `action.run`'s `result`: only these keys, and never a token (the machine has the only one).
    static func fields(_ outcome: Outcome, identity: GitIdentity, fallback: Fallback?) -> [String: ActionResultValue] {
        var fields: [String: ActionResultValue] = ["ok": .bool(outcome.ok), "gh_status": .string(outcome.gitHub.rawValue),
                                                   "method": .string(outcome.gitHub == .app ? "app" : "device")]
        if let fallback { fields["fallback_reason"] = .string(fallback.rawValue) }
        if outcome.identity == .set {
            if let name = identity.name { fields["user_name"] = .string(name) }
            if let email = identity.email { fields["user_email"] = .string(email) }
        }
        if let code = outcome.deviceCode {
            fields["device_code"] = .string(code)
            fields["verification_uri"] = .string(verificationURI)
        }
        return fields
    }

    /// The toast a person sees after the run: when the machine signed in itself, why first.
    static func summary(_ outcome: Outcome, fallback: Fallback?) -> String {
        var gitHub: String
        switch outcome.gitHub {
        case .app: gitHub = CloudStrings.gitHubAppReady
        case .pending: gitHub = CloudStrings.gitHubEnterCode(outcome.deviceCode ?? "")
        case .loggedIn: gitHub = CloudStrings.gitHubAlreadySignedIn
        case .missing: gitHub = CloudStrings.gitHubMissing
        case .failed: gitHub = CloudStrings.gitHubFailed
        }
        if let fallback { gitHub = CloudStrings.gitHubFallback(fallback) + " " + gitHub }
        return outcome.identity == .failed ? CloudStrings.gitHubIdentityFailed + " " + gitHub : gitHub
    }
}
