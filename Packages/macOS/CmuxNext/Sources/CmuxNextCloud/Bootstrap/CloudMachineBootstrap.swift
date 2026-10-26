public import Foundation

/// `cloud new-machine --bootstrap-script FILE`: the script goes to the new machine over the Cloud
/// file API (the signed-in person's authenticated link; no ssh, no exec payload), next to a small
/// runner, and one short exec starts the runner detached under systemd, so a long bootstrap (the
/// lane bootstrap installs tools for minutes) never meets the exec API's 25 s limit. The runner
/// runs the script as the machine's user, logs to ``logPath`` and writes ``statusPath``
/// (`{"state":"running|done|failed","exit_code":N,"script_sha256":"…","at":unix}`), and ends
/// when the script does. A rerun of the same script while it runs or after it finished starts
/// nothing.
public struct CloudMachineBootstrap: Equatable, Sendable {
    public enum Kind: String, Sendable { case plain, lane }

    public var kind: Kind
    public var contents: Data

    public init(kind: Kind, contents: Data) {
        self.kind = kind
        self.contents = contents
    }

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

    /// How a start went: `started`, `running` (a run of this script is under way), `skipped`
    /// (this script already finished here) or `failed` with its `reason`.
    public struct Outcome: Equatable, Sendable {
        public var status: String
        public var reason: String?

        public init(status: String, reason: String? = nil) {
            self.status = status
            self.reason = reason
        }
    }

    /// Uploads the script with its environment and the runner, then starts the runner.
    public func start(name: String?, on machine: Machine) async -> Outcome {
        let tail = { (ran: CloudExecResult) in String((ran.stderr.isEmpty ? ran.stdout : ran.stderr).suffix(500)) }
        do {
            // The directory belongs to the machine's user, so its runner can write the log and status.
            let made = try await machine.exec(Self.prepareCommand)
            guard made.exitCode == 0 else { return Outcome(status: "failed", reason: tail(made)) }
            try await machine.write(Self.directory + "/script", contents, 0o700)
            try await machine.write(Self.directory + "/env", Data(Self.environment(kind, name: name).utf8), 0o600)
            try await machine.write(Self.directory + "/run", Data(Self.runner.utf8), 0o700)
            let ran = try await machine.exec(Self.startCommand)
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

    /// Runs as the machine's user (uid 1000, `cmux`), the public exec's account.
    public static let prepareCommand = "mkdir -p \(directory) && chmod 700 \(directory)"

    /// The file API may write as root, so the files are handed back to the machine's user, and a
    /// start that cannot own them fails here instead of in the runner. A runner holds `lock`
    /// while it runs (systemd or not), so a second start says `running`. The runner goes to a
    /// transient systemd unit (it outlives the exec); without systemd, passwordless sudo, or when
    /// `systemd-run` fails, it gets `setsid`.
    public static let startCommand = [
        "set -eu", "d=\(directory)",
        #"sudo -n chown -R "$(id -u):$(id -g)" "$d" 2>/dev/null || true"#,
        #"for f in script env run; do [ -O "$d/$f" ] || { echo "$d/$f is not the machine user's and passwordless sudo is unavailable" >&2; exit 1; }; done"#,
        #"if ! flock -n "$d/lock" true; then echo running; exit 0; fi"#,
        #"sum=$(sha256sum "$d/script" | cut -d' ' -f1)"#,
        #"if grep -q "\"state\":\"done\".*\"script_sha256\":\"$sum\"" "$d/status.json" 2>/dev/null; then echo skipped; exit 0; fi"#,
        #"if command -v systemd-run >/dev/null 2>&1 && sudo -n true 2>/dev/null && { sudo -n systemctl reset-failed \#(unit) 2>/dev/null || true; sudo -n systemd-run --quiet --collect --unit=\#(unit) --uid="$(id -u)" --gid="$(id -g)" --setenv=HOME="$HOME" --working-directory="$HOME" "$d/run"; }; then :; else setsid nohup "$d/run" >/dev/null 2>&1 </dev/null & fi"#,
        "echo started",
    ].joined(separator: "; ")

    /// The runner (`~/.cmux/bootstrap/run`).
    public static let runner = #"""
        #!/bin/sh
        # cmux machine bootstrap runner, written by the cmux app (cmux cloud new-machine
        # --bootstrap-script). Runs ./script, logs to ./bootstrap.log, writes ./status.json.
        set -u
        d=$(cd "$(dirname "$0")" && pwd)
        # One runner at a time; a start while this one runs says `running`.
        exec 9>"$d/lock"
        flock -n 9 || exit 0
        sum=$(sha256sum "$d/script" | cut -d' ' -f1)
        status() {
          printf '{"state":"%s","exit_code":%s,"script_sha256":"%s","at":%s}\n' "$1" "$2" "$sum" "$(date +%s)" >"$d/status.json.tmp" &&
            mv -f "$d/status.json.tmp" "$d/status.json"
        }
        status running null
        [ -f "$d/env" ] && . "$d/env"
        cd "$HOME" 2>/dev/null || cd /
        printf '== cmux bootstrap %s at %s\n' "$sum" "$(date -u +%FT%TZ)" >>"$d/bootstrap.log"
        "$d/script" >>"$d/bootstrap.log" 2>&1 </dev/null
        code=$?
        if [ "$code" -eq 0 ]; then status done 0; else status failed "$code"; fi
        exit "$code"
        """#
}
