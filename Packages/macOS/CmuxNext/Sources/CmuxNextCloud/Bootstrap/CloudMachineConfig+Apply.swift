public import Foundation

/// Starting the applier (``CloudMachineConfig/applier``) on a machine: one upload per file over the
/// Cloud file API, then one short exec.
extension CloudMachineConfig {
    /// Uploads the applier and stages this request (`requests/<ms>-<id>.toml` and `.pending`); the
    /// start command hands them to the machine's user and only then renames `.pending` to `.json`,
    /// which marks the request complete, and starts the applier. A running applier takes the newest staged request
    /// after its current one, so two applies never overwrite each other's input.
    public func apply(on machine: CloudMachineBootstrap.Machine, now: Date = Date()) async -> CloudMachineBootstrap.Outcome {
        let tail = { (ran: CloudExecResult) in String((ran.stderr.isEmpty ? ran.stdout : ran.stderr).suffix(500)) }
        do {
            let made = try await machine.exec(Self.prepareCommand)
            guard made.exitCode == 0 else { return .init(status: "failed", reason: tail(made)) }
            let id = Self.requestID(now)
            // This request's own copy: the start command moves it over `apply` once it is the work user's,
            // so a concurrent apply never replaces the file another one is about to run.
            try await machine.write("\(Self.directory)/requests/\(id).apply", Data(Self.applier.utf8), 0o700)
            if let contents { try await machine.write("\(Self.directory)/requests/\(id).toml", contents, 0o600) }
            let request = #"{"source":"\#(contents == nil ? "auto" : "uploaded")"}"# + "\n"
            try await machine.write("\(Self.directory)/requests/\(id).pending", Data(request.utf8), 0o600)
            let ran = try await machine.exec(Self.startCommand(request: id))
            let said = ran.stdout.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
            guard ran.exitCode == 0, ["started", "running"].contains(said) else { return .init(status: "failed", reason: tail(ran)) }
            return .init(status: said)
        } catch {
            return .init(status: "failed", reason: String(describing: error))
        }
    }

    /// A request's name: unix ms, zero-padded so names sort by time, and a random part.
    public static func requestID(_ now: Date) -> String {
        String(format: "%013lld-", Int64(now.timeIntervalSince1970 * 1000)) + UUID().uuidString.prefix(8).lowercased()
    }

    /// As ``CloudMachineBootstrap/prepareCommand``, from root or the work user (``CloudMachineBootstrap/user``):
    /// the folders are the work user's and 0700, and none on the way may be a symlink (uploads and
    /// the applier's cleanup would follow it).
    public static let prepareCommand = [
        "set -eu", CloudMachineBootstrap.rootHelper, "d=\(directory)", "u=\(CloudMachineBootstrap.user)", #"h=$(getent passwd "$u" | cut -d: -f6)"#,
        #"for p in "$h/.cmux" "$d" "$d/requests"; do [ -L "$p" ] && { echo "$p is a symlink" >&2; exit 1; }; done"#,
        #"root mkdir -p "$d/requests" && root chown "$u:$u" "$h/.cmux" "$d" "$d/requests" && root chmod 700 "$d" "$d/requests""#,
    ].joined(separator: "; ")

    /// As ``CloudMachineBootstrap/startCommand``: the files go to the work user (checked by owner
    /// name), a request becomes complete only then, a running applier (its lock) answers `running`,
    /// and the applier runs as the work user with its home in a transient systemd unit (python3 by
    /// its absolute path: an older systemd-run does not search PATH), else under `setsid`. The unit's
    /// control group goes with it: a setup command that escaped its process group (`setsid`, a daemon)
    /// is stopped when the apply ends; the no-systemd fallback cannot do that. It needs
    /// python3 with `tomllib` (3.11+; Ubuntu 24.04 has 3.12).
    /// Finalizes only `request`'s own files (an applier may be taking others, and another writer may still
    /// be staging its own), then starts the applier.
    public static func startCommand(request: String) -> String { [
        "set -eu", CloudMachineBootstrap.rootHelper, CloudMachineBootstrap.userHelper,
        "d=\(directory)", "u=\(CloudMachineBootstrap.user)", "r=\(request)", #"h=$(getent passwd "$u" | cut -d: -f6)"#,
        #"for p in "$h/.cmux" "$d" "$d/requests"; do [ -L "$p" ] && { echo "$p is a symlink" >&2; exit 1; }; done"#,
        // After the symlink check: only the known staged files, never a link (-h), never a whole tree.
        #"root chown -h "$u:$u" "$d" "$d/requests" "$d/requests/$r.apply" "$d/requests/$r.pending" $([ -e "$d/requests/$r.toml" ] && echo "$d/requests/$r.toml") 2>/dev/null || true"#,
        #"for f in requests requests/$r.apply requests/$r.pending $([ -e "$d/requests/$r.toml" ] && echo requests/$r.toml); do [ "$(stat -c %U "$d/$f")" = "$u" ] || { echo "$d/$f is not $u's: the start needs root or passwordless sudo" >&2; exit 1; }; done"#,
        // Owned now: the applier replaces the shared one in one rename (a running one keeps its open file).
        #"as_u mv -f "$d/requests/$r.apply" "$d/apply""#,
        #"py=$(command -v python3) && "$py" -I -c 'import tomllib' 2>/dev/null || { echo "the machine has no python3 with tomllib (3.11 or later)" >&2; exit 1; }"#,
        // Owned now: this request becomes complete (and visible to a running applier) only here.
        #"as_u mv -f "$d/requests/$r.pending" "$d/requests/$r.json""#,
        #"if ! as_u flock -n "$d/lock" true; then echo running; exit 0; fi"#,
        #"if command -v systemd-run >/dev/null 2>&1 && { root systemctl reset-failed \#(unit) 2>/dev/null || true; root systemd-run --quiet --collect --unit=\#(unit) --property=KillMode=control-group --uid="$u" --gid="$u" --setenv=HOME="$h" --working-directory="$h" "$py" -I "$d/apply"; }; then :; else command -v setsid >/dev/null 2>&1 || { echo "the machine has neither a working systemd-run nor setsid to start the applier" >&2; exit 1; }; as_u env HOME="$h" setsid nohup "$py" -I "$d/apply" >/dev/null 2>&1 </dev/null & fi"#,
        "echo started",
    ].joined(separator: "; ") }
}
