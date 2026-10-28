public import Foundation

/// `cloud new-machine --bootstrap-script FILE`: the script goes to the new machine over the Cloud
/// file API (the signed-in person's authenticated link; no ssh, no exec payload), next to a small
/// runner, and one short exec starts the runner detached under systemd, so a long bootstrap (the
/// lane bootstrap installs tools for minutes) never meets the exec API's 25 s limit. The runner
/// runs the script as the machine's user, logs to ``logPath`` and writes ``statusPath``
/// (`{"state":"running|done|failed","exit_code":N,"script_sha256":"…","start_sha256":"…","at":unix}`), and ends
/// when the script does. One runner at a time: a start while one runs says `running`, and a start
/// whose script and repo step finished last runs nothing. With a ``repo`` the runner clones it first (``CloudMachineRepo``; `status.json`'s
/// `repo`), and a machine with only `--repo` runs ``noScript``.
public struct CloudMachineBootstrap: Equatable, Sendable {
    public enum Kind: String, Sendable, Equatable { case plain, lane }

    public var kind: Kind
    public var contents: Data
    public var repo: CloudMachineRepo?

    public init(kind: Kind, contents: Data, repo: CloudMachineRepo? = nil) {
        self.kind = kind
        self.contents = contents
        self.repo = repo
    }

    /// The script of a machine that only clones a repository.
    public static let noScript = Data("#!/bin/sh\nexit 0\n".utf8)

    public static let directory = "/home/cmux/.cmux/bootstrap"
    public static let logPath = directory + "/bootstrap.log"
    public static let statusPath = directory + "/status.json"
    /// The transient unit the runner runs in (`systemctl status cmux-machine-bootstrap`).
    public static let unit = "cmux-machine-bootstrap"
    /// The longest script the app uploads (the lane bootstrap is about 47 KB).
    public static let maxBytes = 1 << 20

    /// The calls a bootstrap makes, over ``CloudAPIClient`` in the app and fakes in tests.
    public struct Machine: Sendable {
        var write: @Sendable (_ path: String, _ data: Data, _ mode: Int) async throws -> Void
        var exec: @Sendable (_ command: String) async throws -> CloudExecResult

        public init(write: @escaping @Sendable (String, Data, Int) async throws -> Void,
                    exec: @escaping @Sendable (String) async throws -> CloudExecResult) {
            self.write = write
            self.exec = exec
        }

        public init(api: CloudAPIClient, machineID: String) {
            self.init(write: { try await api.writeFile(machineID, path: $0, data: $1, mode: $2) },
                      exec: { try await api.exec(machineID, command: $0, timeoutMs: 20_000) })
        }
    }

    /// How a start went: `started`, `running` (another start's run is under way; this one's files are
    /// dropped), `skipped` (this script and repo step already finished here) or `failed` with its `reason`.
    public struct Outcome: Equatable, Sendable {
        public var status: String
        public var reason: String?

        public init(status: String, reason: String? = nil) {
            self.status = status
            self.reason = reason
        }
    }

    /// Uploads the script with its environment, the runner and the repo step into a folder of
    /// this start's own, then starts: no upload ever changes the files a running runner runs.
    /// `repositoryOnly` refuses to replace an existing setup with different script or repo contents.
    public func start(name: String?, on machine: Machine, startID: String = UUID().uuidString.lowercased(), repositoryOnly: Bool = false) async -> Outcome {
        let tail = { (ran: CloudExecResult) in String((ran.stderr.isEmpty ? ran.stdout : ran.stderr).suffix(500)) }
        let staged = Self.stagingDirectory(startID)
        do {
            // The directory belongs to the machine's user, so its runner can write the log and status.
            let made = try await machine.exec(Self.prepareCommand(staged))
            guard made.exitCode == 0 else { return Outcome(status: "failed", reason: tail(made)) }
            try await machine.write(staged + "/script", contents, 0o700)
            try await machine.write(staged + "/env", Data(Self.environment(kind, name: name).utf8), 0o600)
            try await machine.write(staged + "/run", Data(Self.runner.utf8), 0o700)
            // Always both, so no step or record of an earlier start is left: no repo is `null` and a no-op.
            try await machine.write(staged + "/repo.json", repo?.record ?? Data("null\n".utf8), 0o644)
            try await machine.write(staged + "/repo", repo.map { Data($0.step.utf8) } ?? Self.noScript, 0o700)
            let ran = try await machine.exec(Self.startCommand(staged, repositoryOnly: repositoryOnly))
            let said = ran.stdout.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
            guard ran.exitCode == 0, ["started", "running", "skipped"].contains(said) else { return Outcome(status: "failed", reason: tail(ran)) }
            return Outcome(status: said)
        } catch {
            return Outcome(status: "failed", reason: String(describing: error))
        }
    }

    /// `export` lines the runner sources: the machine's name, and for the lane bootstrap the
    /// lane host name it reads (`LANE_VM_NAME`; leo-workspace tools/lane-vm-bootstrap).
    public static func environment(_ kind: Kind, name: String?) -> String {
        guard let name else { return "" }
        var lines = ["export CMUX_MACHINE_NAME=\(shellQuoted(name))"]
        if kind == .lane { lines.append("export LANE_VM_NAME=\(shellQuoted(name))") }
        return lines.joined(separator: "\n") + "\n"
    }

    static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// A start's own upload folder (`in-<id>`, the id a UUID: no quoting needed).
    public static func stagingDirectory(_ startID: String) -> String { directory + "/in-" + startID.filter { $0.isHexDigit || $0 == "-" } }

    /// The image's work user (uid 1000), whose home holds ``directory``. The exec API may run a
    /// command as root or as this user (the provider's default differs by path), so every
    /// command names it: as root it acts directly, as the user through passwordless sudo.
    public static let user = "cmux"

    /// `root CMD`: CMD as root, from either account.
    static let rootHelper = #"root() { if [ "$(id -u)" = 0 ]; then "$@"; else sudo -n "$@"; fi; }"#
    /// `as_u CMD`: CMD as the work user `$u`, from either account.
    static let userHelper = #"as_u() { if [ "$(id -un)" = "$u" ]; then "$@"; else root runuser -u "$u" -- "$@"; fi; }"#

    /// No folder on the way may be a symlink: root's chown and chmod would follow it out of the home folder.
    static let noSymlinks = #"for p in "$h/.cmux" "$d"; do [ -L "$p" ] && { echo "$p is a symlink" >&2; exit 1; }; done"#

    /// The bootstrap folder and this start's upload folder, the work user's, before the uploads.
    public static func prepareCommand(_ staged: String) -> String { [
        "set -eu", rootHelper, "d=\(directory)", "s=\(staged)", "u=\(user)", #"h=$(getent passwd "$u" | cut -d: -f6)"#, noSymlinks,
        #"root mkdir -p "$d" && root chown -h \#(user):\#(user) "$d" && root chmod 700 "$d""#,
        #"[ -L "$s" ] && { echo "$s is a symlink" >&2; exit 1; }; root mkdir -p "$s" && root chown -h \#(user):\#(user) "$s" && root chmod 700 "$s""#,
    ].joined(separator: "; ") }

    /// The file API may write as root, so the files go to the work user first, and a start that
    /// cannot hand them over fails here instead of in the runner. Uploads land in this start's
    /// own folder, so no upload ever changes the files a running runner runs: the start moves
    /// them into the bootstrap folder only while it holds the runner's lock, and a start while a
    /// runner runs, or while an earlier start's runner has not taken over yet (its `starting`, for
    /// up to a minute, the applier's wait too), says `running` and drops its files. The runner always runs as the work user
    /// with its home, in a transient systemd unit (it outlives the exec); without systemd, or
    /// when `systemd-run` fails, under `setsid`.
    public static func startCommand(_ staged: String, repositoryOnly: Bool = false) -> String { [
        "set -eu", rootHelper, userHelper, "d=\(directory)", "s=\(staged)", "u=\(user)", #"h=$(getent passwd "$u" | cut -d: -f6)"#, noSymlinks,
        // Exclusive against a machine-config apply (it holds this shared for its whole run): from here until
        // `starting` is out, so an apply either sees this start or this start waits for it (15 s, then a
        // clear refusal). Opened read-only and only once it exists and is no link: root never creates or
        // writes through a link the work user planted.
        #"[ -e "$d/start.lock" ] || as_u touch "$d/start.lock"; { [ -f "$d/start.lock" ] && [ ! -L "$d/start.lock" ]; } || { echo "$d/start.lock is not a regular file" >&2; exit 1; }; exec 7<"$d/start.lock""#,
        #"flock -w 15 7 || { echo "a machine config apply is running on this machine: start the bootstrap again when it ends" >&2; exit 1; }"#,
        #"root chown -hR "$u:$u" "$d" 2>/dev/null || true"#,
        #"[ -d "$s" ] && [ ! -L "$s" ] || { echo "$s is not a folder" >&2; exit 1; }"#,
        #"for f in script env run repo repo.json; do { [ -f "$s/$f" ] && [ ! -L "$s/$f" ] && [ "$(stat -c %U "$s/$f")" = "$u" ]; } || { echo "$s/$f is not $u's: the start needs root or passwordless sudo" >&2; exit 1; }; done"#,
        // The runner's own lock, held from the `running` check until `starting` is out (opened read-only, a
        // regular file of the work user's, like start.lock): a runner an earlier start launched that only now
        // gets to run finds it taken and exits, so it never runs the files between this start's move and its
        // `starting`. Let go before the launch, so this start's runner can take it.
        #"[ -e "$d/lock" ] || as_u touch "$d/lock"; { [ -f "$d/lock" ] && [ ! -L "$d/lock" ]; } || { echo "$d/lock is not a regular file" >&2; exit 1; }; exec 6<"$d/lock""#,
        #"flock -n 6 || { as_u rm -rf "$s" || true; echo running; exit 0; }"#,
        // An earlier start launched a runner that has not taken over yet: its files are not replaced under it.
        // After a minute without it (the applier's wait for a `starting` too) that start counts as dead.
        #"at=$(sed -n 's/^{"state":"starting".*"at":\([0-9]*\)}$/\1/p' "$d/status.json" 2>/dev/null || true)"#,
        #"if [ -n "$at" ] && [ $(( $(date +%s) - at )) -lt 60 ]; then as_u rm -rf "$s" || true; echo running; exit 0; fi"#,
        // A repo retry may never replace a different repo or a custom setup script. Check under the
        // runner lock, so a concurrent start cannot change either between the check and the move.
        repositoryOnly ? #"if ! cmp -s "$d/script" "$s/script" || ! cmp -s "$d/repo.json" "$s/repo.json"; then as_u rm -rf "$s"; echo 'repository retry does not match the original repository-only setup' >&2; exit 1; fi"# : ":",
        // No runner runs: this start's files become the bootstrap folder's (a rename each, as the work user),
        // where the runner and a machine-config apply read them (`script`, `repo.json`).
        #"for f in script env run repo repo.json; do as_u mv -f "$s/$f" "$d/$f"; done; as_u rm -rf "$s""#,
        // `script_sha256` is the script's; `start_sha256` is the script's and the repo step's, which say
        // together what a start runs: the same pair done already runs nothing.
        #"sum=$(sha256sum "$d/script" | cut -d' ' -f1); key=$(cat "$d/script" "$d/repo" | sha256sum | cut -d' ' -f1)"#,
        #"if grep -q "\"state\":\"done\".*\"start_sha256\":\"$key\"" "$d/status.json" 2>/dev/null; then echo skipped; exit 0; fi"#,
        #"as_u rm -f "$d/repo-status.json""#,
        // Only when a runner is launched: a machine-config applier waits on `starting` (a retry of a failed
        // script too). The runner takes `alive` once it runs, which the applier waits on too.
        #"printf '{"state":"starting","exit_code":null,"script_sha256":"%s","start_sha256":"%s","at":%s}\n' "$sum" "$key" "$(date +%s)" | as_u tee "$d/status.json" >/dev/null"#,
        "exec 6<&-",
        #"if command -v systemd-run >/dev/null 2>&1 && { root systemctl reset-failed \#(unit) 2>/dev/null || true; root systemd-run --quiet --collect --unit=\#(unit) --uid="$u" --gid="$u" --setenv=HOME="$h" --working-directory="$h" "$d/run"; }; then :; else as_u env HOME="$h" setsid nohup "$d/run" >/dev/null 2>&1 </dev/null 7<&- & fi"#,
        "echo started",
    ].joined(separator: "; ") }

    /// The runner (`run` in ``directory``).
    public static let runner = #"""
        #!/bin/sh
        # cmux machine bootstrap runner, written by the cmux app (cmux cloud new-machine
        # --bootstrap-script, --repo). Runs ./repo, then ./script, logs to ./bootstrap.log,
        # writes ./status.json.
        set -u
        d=$(cd "$(dirname "$0")" && pwd)
        # One runner at a time; a start while this one runs says `running`.
        exec 9>"$d/lock"
        flock -n 9 || exit 0
        sum=$(sha256sum "$d/script" | cut -d' ' -f1)
        key=$(cat "$d/script" "$d/repo" | sha256sum | cut -d' ' -f1)
        # A runner launched by an earlier start may have run these files to their end while this one waited
        # to be scheduled: a script and repo step that are done are not run again.
        if grep -q "\"state\":\"done\".*\"start_sha256\":\"$key\"" "$d/status.json" 2>/dev/null; then exit 0; fi
        # Held for the runner's whole life, taken blocking: a machine-config apply probes it (shared,
        # non-blocking, released at once) to wait while this runner runs; the kernel drops it at the end.
        [ -f "$d/alive" ] && [ ! -L "$d/alive" ] || rm -f "$d/alive"
        exec 8>"$d/alive"
        flock 8
        status() {
          repo=$(cat "$d/repo-status.json" 2>/dev/null || echo null)
          printf '{"state":"%s","exit_code":%s,"script_sha256":"%s","start_sha256":"%s","repo":%s,"at":%s%s}\n' "$1" "$2" "$sum" "$key" "$repo" "$(date +%s)" "${3:-}" >"$d/status.json.tmp" &&
            mv -f "$d/status.json.tmp" "$d/status.json"
        }
        # A runner that comes a minute or more after its start's `starting` does not run: a machine-config apply
        # waits that long for a start whose runner never came (with `alive` free), then applies, and a bootstrap
        # never runs beside it. Checked once `alive` is held, which the apply sees from then on.
        at=$(sed -n 's/^{"state":"starting".*"at":\([0-9]*\)}$/\1/p' "$d/status.json" 2>/dev/null)
        if [ -n "$at" ] && [ $(( $(date +%s) - at )) -ge 60 ]; then
          printf '== cmux bootstrap %s: its runner came %ss after the start; start it again\n' "$key" "$(( $(date +%s) - at ))" >>"$d/bootstrap.log"
          status failed 75 ',"late":true'; exit 75
        fi
        # Not its locks: a daemon the repo step or the script leaves running must not keep them held after this runner ends.
        repo_step() { "$d/repo" >>"$d/bootstrap.log" 2>&1 </dev/null 8>&- 9>&-; }
        status running null
        [ -f "$d/env" ] && . "$d/env"
        cd "$HOME" 2>/dev/null || cd /
        printf '== cmux bootstrap %s at %s\n' "$key" "$(date -u +%FT%TZ)" >>"$d/bootstrap.log"
        repo_step
        repo_code=$?
        # \#(CloudMachineRepo.needsGitHubExit): the repo needs GitHub access the script may set up (a lane VM's broker helper); try again after it.
        if [ "$repo_code" -ne 0 ] && [ "$repo_code" -ne \#(CloudMachineRepo.needsGitHubExit) ]; then status failed "$repo_code" ',"step":"repo"'; exit "$repo_code"; fi
        "$d/script" >>"$d/bootstrap.log" 2>&1 </dev/null 8>&- 9>&-
        code=$?; step=script
        if [ "$code" -eq 0 ] && [ "$repo_code" -ne 0 ]; then repo_step; code=$?; step=repo; fi
        # `step`: which step failed, so a reader never takes a script's exit code for the repo step's.
        if [ "$code" -eq 0 ]; then status done 0; else status failed "$code" ",\"step\":\"$step\""; fi
        exit "$code"
        """#
}
