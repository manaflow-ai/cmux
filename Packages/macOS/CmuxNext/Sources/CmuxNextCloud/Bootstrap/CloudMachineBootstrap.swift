public import Foundation

/// `cloud new-machine --bootstrap-script FILE`: the script goes to the new machine over the Cloud
/// file API (the signed-in person's authenticated link; no ssh, no exec payload), next to a small
/// runner, and one short exec starts the runner detached under systemd, so a long bootstrap (the
/// lane bootstrap installs tools for minutes) never meets the exec API's 25 s limit. The runner
/// runs the script as the machine's user, logs to ``logPath`` and writes ``statusPath``
/// (`{"state":"running|done|failed","exit_code":N,"script_sha256":"…","at":unix}`), and ends
/// when the script does. Starts queue, one runner at a time; a start whose script and repo step
/// finished last runs nothing. With a ``repo`` the runner clones it first (``CloudMachineRepo``; `status.json`'s
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
    /// The transient units the runners run in, one per start (`systemctl list-units 'cmux-machine-bootstrap-*'`).
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

    /// How a start went: `started`, `queued` (it runs after the run under way; a runner whose files
    /// finished last skips them) or `failed` with its `reason`.
    public struct Outcome: Equatable, Sendable {
        public var status: String
        public var reason: String?

        public init(status: String, reason: String? = nil) {
            self.status = status
            self.reason = reason
        }
    }

    /// Uploads the script with its environment, the runner and the repo step into a folder of
    /// this start's own, then starts the runner on that folder: no start ever changes the files
    /// another start's runner runs.
    public func start(name: String?, on machine: Machine, startID: String = UUID().uuidString.lowercased()) async -> Outcome {
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
            let ran = try await machine.exec(Self.startCommand(staged))
            let said = ran.stdout.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
            guard ran.exitCode == 0, ["started", "queued"].contains(said) else { return Outcome(status: "failed", reason: tail(ran)) }
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

    /// The bootstrap folder and this start's upload folder, the work user's, before the uploads.
    public static func prepareCommand(_ staged: String) -> String { [
        "set -eu", rootHelper, "d=\(directory)", "s=\(staged)",
        #"root mkdir -p "$d" "$s" && root chown \#(user):\#(user) "$d" "$s" && root chmod 700 "$d" "$s""#,
    ].joined(separator: "; ") }

    /// The file API may write as root, so the files go to the work user first, and a start that
    /// cannot hand them over fails here instead of in the runner. The runner starts on this
    /// start's own folder, always as the work user with its home: it waits for the lock (`queued`
    /// behind a runner that holds it), skips when the same files finished last (only it decides,
    /// under the lock, so no start is lost), and runs them. A transient systemd unit per start (it
    /// outlives the exec); without systemd, or when `systemd-run` fails, under `setsid`.
    public static func startCommand(_ staged: String) -> String { [
        "set -eu", rootHelper, userHelper, "d=\(directory)", "s=\(staged)", "u=\(user)", #"h=$(getent passwd "$u" | cut -d: -f6)"#,
        #"root chown -R "$u:$u" "$d" 2>/dev/null || true"#,
        #"for f in script env run repo repo.json; do [ "$(stat -c %U "$s/$f")" = "$u" ] || { echo "$s/$f is not $u's: the start needs root or passwordless sudo" >&2; exit 1; }; done"#,
        #"said=started; as_u flock -n "$d/lock" true || said=queued; n=\#(unit)-$(basename "$s")"#,
        #"if command -v systemd-run >/dev/null 2>&1 && root systemd-run --quiet --collect --unit="$n" --uid="$u" --gid="$u" --setenv=HOME="$h" --working-directory="$h" "$s/run" "$s"; then :; else as_u env HOME="$h" setsid nohup "$s/run" "$s" >/dev/null 2>&1 </dev/null & fi"#,
        #"echo "$said""#,
    ].joined(separator: "; ") }

    /// The runner (`run` in a start's own folder, given that folder).
    public static let runner = #"""
        #!/bin/sh
        # cmux machine bootstrap runner, written by the cmux app (cmux cloud new-machine
        # --bootstrap-script, --repo). Runs its start's ./repo, then ./script, one start at a time,
        # logs to ../bootstrap.log, writes ../status.json; the files stay in ../current.
        set -u
        s=$1
        d=$(cd "$s/.." && pwd)
        # One runner at a time, in the order they got here; each start keeps its own files.
        exec 9>"$d/lock"
        flock 9 || exit 1
        sum=$(cat "$s/script" "$s/repo" | sha256sum | cut -d' ' -f1)
        if grep -q "\"state\":\"done\".*\"script_sha256\":\"$sum\"" "$d/status.json" 2>/dev/null; then rm -rf "$s"; exit 0; fi
        r="$d/current"
        rm -rf "$r" && mv "$s" "$r" || exit 1
        status() {
          repo=$(cat "$r/repo-status.json" 2>/dev/null || echo null)
          printf '{"state":"%s","exit_code":%s,"script_sha256":"%s","repo":%s,"at":%s}\n' "$1" "$2" "$sum" "$repo" "$(date +%s)" >"$d/status.json.tmp" &&
            mv -f "$d/status.json.tmp" "$d/status.json"
        }
        repo_step() { "$r/repo" >>"$d/bootstrap.log" 2>&1 </dev/null; }
        status running null
        . "$r/env"
        cd "$HOME" 2>/dev/null || cd /
        printf '== cmux bootstrap %s at %s\n' "$sum" "$(date -u +%FT%TZ)" >>"$d/bootstrap.log"
        repo_step
        repo_code=$?
        # \#(CloudMachineRepo.needsGitHubExit): the repo needs GitHub access the script may set up (a lane VM's broker helper); try again after it.
        if [ "$repo_code" -ne 0 ] && [ "$repo_code" -ne \#(CloudMachineRepo.needsGitHubExit) ]; then status failed "$repo_code"; exit "$repo_code"; fi
        "$r/script" >>"$d/bootstrap.log" 2>&1 </dev/null
        code=$?
        if [ "$code" -eq 0 ] && [ "$repo_code" -ne 0 ]; then repo_step; code=$?; fi
        if [ "$code" -eq 0 ]; then status done 0; else status failed "$code"; fi
        exit "$code"
        """#
}
