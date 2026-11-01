import CmuxNextCloud
import CmuxNextRemote
import Foundation

/// The update of a Cloud machine too old to update in place: its daemon serves neither `fs-v1` nor
/// `detached-terminals-v1`, so `cmux link machine update` answers `machine_update_unsupported`.
/// Such a machine still has the Cloud API's exec, the channel the image bake and the fleet upgrade
/// use. Through it the app runs the fleet's own guest upgrade (`cmux-tui-upgrade.sh`, a copy of
/// `web/scripts/cloud-vm/cmux-tui-upgrade.sh`; docs/cloud-guest-upgrades.md) to install the app's
/// own pinned Linux build: as root, detached from the exec in a transient systemd unit, under the
/// machine's one upgrade lock. One exec starts the run; each later one waits on it, at most a few
/// minutes (the provider ends an exec after 5), until it writes its result. It backs up the running binary, installs the pinned one, ends only
/// the daemon (every terminal host and chat keeps running), waits for the new daemon to serve and
/// to keep every host, and rolls back otherwise. The new build serves `fs-v1`, so the machine's
/// later updates go in place.
///
/// Nothing the CLI or an agent passes reaches it: the build is the app's own pin (``CloudLegacyPin``:
/// the bundle's manifest, or for a DEV build the published pin of its own commit or cmux-tui tree,
/// as `cmux link machine update` resolves it), the machine checks the download against that pin's
/// SHA-256 before it replaces anything, and the script is the app's own resource.
nonisolated enum CloudLegacyMachineUpdate {
    /// The app's pinned Linux build for Cloud machines.
    typealias Pin = CloudLegacyPin

    /// The fleet upgrade's directory: its runs share `lock`, so the app's run and an operator's
    /// never overlap on one machine.
    static let directory = "/var/lib/cmux-tui-upgrade"
    /// One wait's bound on the machine, under the provider's 5-minute exec.
    static let waitSeconds = 270
    /// Waits before the app stops asking (about 27 minutes, past the guest script's own bounds
    /// for a healthy daemon, like `cmux link machine update`'s 25). A run that goes on after it
    /// ends by itself, and the machine then reports its build.
    static let waits = 6

    /// The guest script, from the app's resources.
    static var script: String? {
        Bundle.module.url(forResource: "cmux-tui-upgrade", withExtension: "sh").flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }

    /// One exec on the machine: the command and its timeout in milliseconds.
    typealias Exec = @Sendable (_ command: String, _ timeoutMs: Int) async throws -> CloudExecResult

    /// Runs the update of a machine through `exec` and answers as `cmux link machine update`
    /// would: one exec starts the run, then up to ``waits`` wait on it. A wait that did not answer
    /// (the provider's timeout, a dropped request) is followed by the next; with none left, or a
    /// start that did not answer, the answer is `machine_update_unresolved`, so the policy asks
    /// again and the machine then reports its build.
    ///
    ///
    /// `expected`: the 40-hex commit `link machine update --if-older` judged older (the automatic
    /// update). The guest script checks it under the machine's upgrade lock and the in-place
    /// updater's lock (both held for its whole run), before it changes anything
    /// (`<run-dir>/expect-build`): a binary updated since (another app or the fleet, maybe to a
    /// newer build), or one that names no commit, is left as it is, `SKIP changed`, so the answer is
    /// `machine_update_busy`, the policy asks again and `--if-older` reads the new build.
    static func run(pin: Pin, script: String, expected: String? = nil, nonce: String = newNonce(), directory: String = directory,
                    waitSeconds: Int = waitSeconds, waits: Int = waits, exec: Exec) async -> CloudMoveCLI.Answer {
        // A start that did not answer, or that the provider ended (exit 124), may have started the
        // run: the waits read what it left. Only a start that ended on its own and said otherwise
        // started nothing, so one wait is enough to read the run that never began.
        let started = try? await exec(startCommand(pin: pin, script: script, nonce: nonce, directory: directory, expected: expected), 60_000)
        if let started, lastLine(started) == "NOROOT" { return answer(started, pin: pin) }
        let refused = started.map { lastLine($0) != "started" && $0.exitCode != 124 } ?? false
        let wait = waitCommand(nonce: nonce, directory: directory, seconds: waitSeconds)
        for _ in 0..<(refused ? 1 : waits) {
            guard let ran = try? await exec(wait, (waitSeconds + 20) * 1000) else { continue }
            let reply = answer(ran, pin: pin)
            if reply.errorCode != "machine_update_unresolved" { return reply }
        }
        if refused, let started { return CloudMoveCLI.Answer(ok: false, errorCode: "machine_update_failed", error: detail(started)) }
        return unresolved("the machine's update did not end within \(waits * waitSeconds / 60) minutes")
    }

    /// The start exec: the run's files go to a fresh directory (runs older than a week go), and the
    /// guest script starts as root in a transient systemd unit (without systemd, under `setsid` in
    /// its own session), detached from the exec. `unit` (the unit's name) or `pid` (the setsid
    /// run's) tells the waits what to wait on. Says `started`, or `NOROOT` from an account that
    /// cannot become root (nothing changed). `expected` (a 40-hex commit; anything else is left
    /// out) goes to `<run-dir>/expect-build`, which the guest script checks under its lock.
    static func startCommand(pin: Pin, script: String, nonce: String, directory: String = directory,
                             expected: String? = nil) -> String {
        let args = "\(pin.sha256) \(pin.commit) \"$r\""
        // It reaches a shell: only a 40-hex commit.
        let expected = expected?.lowercased()
        let expectBuild = expected.flatMap { CloudLegacyPin.isHex($0, count: 40) ? [writeFile($0 + "\n", to: "$r/expect-build")] : nil } ?? []
        let lines: [String] = [
            "set -eu",
            rootHelper,
            "root true 2>/dev/null || { echo NOROOT; exit 0; }",
            "d=\(directory); r=\"$d/app-\(nonce)\"",
            #"root mkdir -p "$r""#,
            #"root find "$d" -maxdepth 1 -name 'app-*' -mtime +7 -exec rm -rf {} + 2>/dev/null || true"#,
            writeFile(installCommand(pin), to: "$r/install.cmd"),
            writeFile(script, to: "$r/upgrade.sh"),
        ] + expectBuild + [
            "if command -v systemd-run >/dev/null 2>&1 && root systemd-run --quiet --collect --unit=\(unit(nonce)) /bin/sh \"$r/upgrade.sh\" \(args) >/dev/null 2>&1; then",
            #"  echo \#(unit(nonce)) | root tee "$r/unit" >/dev/null"#,
            "else",
            // sudo's command is the shell, which ends at once: the run is its child's, not sudo's.
            // In a shell with no job control the background job leads no group, so setsid and
            // nohup exec in place and `$!` is the run's own pid.
            "  pid=$(root sh -c 'setsid nohup /bin/sh \"$1\" \"$2\" \"$3\" \"$4\" </dev/null >/dev/null 2>&1 & echo $!' sh \"$r/upgrade.sh\" \(args))",
            #"  printf '%s\n' "$pid" | root tee "$r/pid" >/dev/null"#,
            "fi",
            "echo started",
        ]
        return lines.joined(separator: "\n")
    }

    /// A wait exec: until the run's process ends, at most `seconds`, then its result line on stdout
    /// and the log's tail on stderr. The unit's main pid is read here, at each wait: `systemd-run`
    /// returned once the unit's process was forked, and a unit that ended (and was collected) has
    /// none, so its result is read at once. A run that ended takes its files and, unless its
    /// rollback failed, the backup of the old binary with it.
    static func waitCommand(nonce: String, directory: String = directory, seconds: Int = waitSeconds) -> String {
        [
            "set -eu",
            rootHelper,
            "r=\(directory)/app-\(nonce)",
            #"if [ -s "$r/unit" ]; then pid=$(root systemctl show -p MainPID --value "$(root cat "$r/unit")" 2>/dev/null || echo 0); else pid=$(root cat "$r/pid" 2>/dev/null || echo 0); fi"#,
            "if [ \"${pid:-0}\" -gt 0 ] 2>/dev/null && root kill -0 \"$pid\" 2>/dev/null; then root timeout \(seconds) tail --pid=\"$pid\" -f /dev/null >/dev/null 2>&1 || true; fi",
            #"line=$(root cat "$r/result" 2>/dev/null || true); root tail -n 15 "$r/log" >&2 2>/dev/null || true"#,
            #"case "$line" in ""|running|PENDING*) ;; "FAIL rollback"*) root rm -f "$r/install.cmd" "$r/upgrade.sh" ;; *) root rm -f "$r/install.cmd" "$r/upgrade.sh" "$r/cmux-tui.prev" ;; esac"#,
            #"printf '%s\n' "$line""#,
        ].joined(separator: "\n")
    }

    /// The pinned install the guest script runs as root (`install.cmd`): the daemon's own layout
    /// (`cmuxTuiLayoutSelector` in web/services/vms/drivers/cmuxTuiDaemon.ts), the pinned binary
    /// downloaded and checked beside it, then renamed over it, owned by the daemon's user so its
    /// later in-place updates can replace it. A binary that already matches the pin stays.
    static func installCommand(_ pin: Pin) -> String {
        let check = { (file: String) in "printf '%s  %s\\n' \(pin.sha256) \"\(file)\" | sha256sum -c >/dev/null 2>&1" }
        return [
            "set -eu",
            layout,
            #"bin="$h/.cmux/bin/cmux-tui"; tmp="$bin.app-update""#,
            "if [ -x \"$bin\" ] && \(check("$bin")); then :; else",
            "  curl -fsSL --retry 3 -o \"$tmp\" '\(pin.url)' && \(check("$tmp")) || { rm -f \"$tmp\"; echo 'the pinned build did not download or match its pin' >&2; exit 1; }",
            #"  chmod 755 "$tmp"; [ "$u" = root ] || chown "$u:$u" "$tmp"; mv -f "$tmp" "$bin""#,
            "fi",
            #"ln -sfn "$bin" /usr/local/bin/cmux-tui"#,
            #""$bin" --version"#,
        ].joined(separator: "\n") + "\n"
    }

    /// The guest script's result line (the last line of a wait's stdout) as a `link machine
    /// update` answer. No line yet, `running`, or an exec the provider ended (exit 124: the run
    /// may still go on) is `machine_update_unresolved`: the next wait asks again.
    static func answer(_ ran: CloudExecResult, pin: Pin) -> CloudMoveCLI.Answer {
        let line = lastLine(ran)
        func failed(_ code: String) -> CloudMoveCLI.Answer { CloudMoveCLI.Answer(ok: false, errorCode: code, error: detail(ran)) }
        switch line.split(separator: " ").first.map(String.init) ?? "" {
        // UNVERIFIED: the new daemon serves and kept every host; only the terminal count was unreadable.
        // `OK already-current`: the daemon already ran the pinned build; nothing restarted.
        case "OK", "UNVERIFIED":
            return CloudMoveCLI.Answer(ok: true, updated: !line.hasPrefix("OK already-current"), build: pin.commit)
        case "ROLLBACK":
            return failed("machine_update_rolled_back")
        case "FAIL":
            return failed("machine_update_failed")
        case "NOROOT":
            return failed("machine_update_unsupported")
        case "SKIP":
            // A daemon the fleet upgrade does not replace (no trusted carrier): not this way.
            if line.hasPrefix("SKIP unsupported-cloud-auth") { return failed("machine_update_unsupported") }
            // Between restarts of a crash-looping daemon: ask again later.
            if line.hasPrefix("SKIP no-daemon") { return failed("machine_unreachable") }
            // Another run holds the lock, too little disk, any other skip: nothing changed; ask
            // again later, never a failure kept for the build.
            return failed("machine_update_busy")
        default:
            if line.isEmpty || line == "running" || line.hasPrefix("PENDING") || ran.exitCode == 124 { return failed("machine_update_unresolved") }
            return failed("machine_update_failed")
        }
    }

    /// The transient unit of run `nonce`.
    static func unit(_ nonce: String) -> String { "cmux-app-tui-update-\(nonce)" }

    /// 16 hex characters: names the run's directory and unit.
    static func newNonce() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(16))
    }

    /// The daemon's user `u` and home `h` (`cmuxTuiLayoutSelector` in
    /// web/services/vms/drivers/cmuxTuiDaemon.ts).
    private static let layout = "if id -u cmux >/dev/null 2>&1 && command -v setpriv >/dev/null 2>&1 && setpriv --reuid=cmux --regid=cmux --init-groups test -w /home/cmux 2>/dev/null && setpriv --reuid=cmux --regid=cmux --init-groups sudo -n true >/dev/null 2>&1; then u=cmux; h=/home/cmux; else u=root; h=/root; fi"

    /// `root CMD`: CMD as root, from the machine's user (passwordless sudo) or root.
    private static let rootHelper = #"root() { if [ "$(id -u)" = 0 ]; then "$@"; else sudo -n "$@"; fi; }"#

    private static func unresolved(_ why: String) -> CloudMoveCLI.Answer {
        CloudMoveCLI.Answer(ok: false, errorCode: "machine_update_unresolved", error: why)
    }

    private static func lastLine(_ ran: CloudExecResult) -> String {
        ran.stdout.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
    }

    /// What a failure says: the result line, else the end of stderr.
    private static func detail(_ ran: CloudExecResult) -> String {
        let line = lastLine(ran)
        return line.isEmpty ? String(ran.stderr.suffix(400)) : line
    }

    /// `echo BASE64 | base64 -d | root tee FILE`: the exec body carries no quoting of its own.
    private static func writeFile(_ contents: String, to file: String) -> String {
        "echo \(Data(contents.utf8).base64EncodedString()) | base64 -d | root tee \"\(file)\" >/dev/null"
    }
}

nonisolated extension CloudLegacyPin {
    /// The immutable per-commit release `cmux link machine update` downloads too.
    var url: String { "\(RemoteInstallPlan.base.absoluteString)/\(commit)/cmux-tui-\(Self.target)" }
}
