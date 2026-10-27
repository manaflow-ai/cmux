import CmuxNextCloud
import CmuxNextRemote
import Foundation

/// The update of a Cloud machine too old to update in place: its daemon serves neither `fs-v1` nor
/// `detached-terminals-v1`, so `cmux link machine update` answers `machine_update_unsupported`.
/// Such a machine still has the Cloud API's exec, the channel the image bake and the fleet upgrade
/// use. Through it the app runs the fleet's own guest upgrade (`cmux-tui-upgrade.sh`, a copy of
/// `web/scripts/cloud-vm/cmux-tui-upgrade.sh`; docs/cloud-guest-upgrades.md) to install the app's
/// own pinned Linux build: as root, detached from the exec in a transient systemd unit, under the
/// machine's one upgrade lock. It backs up the running binary, installs the pinned one, ends only
/// the daemon (every terminal host and chat keeps running), waits for the new daemon to serve and
/// to keep every host, and rolls back otherwise. The new build serves `fs-v1`, so the machine's
/// later updates go in place.
///
/// Nothing the CLI or an agent passes reaches it: the build is the app bundle's own pin
/// (`Resources/bin/cmux-tui-ssh/manifest.json`, the one `cmux link machine update` reads), the
/// machine checks the download against that pin's SHA-256 before it replaces anything, and the
/// script is the app's own resource.
nonisolated enum CloudLegacyMachineUpdate {
    /// The app's pinned Linux build for Cloud machines.
    struct Pin: Sendable, Equatable {
        /// The build's commit: the `build` its daemon reports.
        var commit: String
        /// SHA-256 of the binary at ``url``.
        var sha256: String

        /// The immutable per-commit release `cmux link machine update` downloads too.
        var url: String { "\(RemoteInstallPlan.base.absoluteString)/\(commit)/cmux-tui-\(CloudLegacyMachineUpdate.target)" }
    }

    /// The Rust target of every Cloud machine's binary (x86_64, the release's static build).
    static let target = "x86_64-unknown-linux-musl"
    /// The fleet upgrade's directory: its runs share `lock`, so the app's run and an operator's
    /// never overlap on one machine.
    static let directory = "/var/lib/cmux-tui-upgrade"
    /// How long the one exec may wait for the run: the route's cap. A run past it goes on, and
    /// the machine then reports its build.
    static let timeoutMs = 900_000

    /// The pin in the manifest beside the app's `cmux` client, nil when the app ships none (dev
    /// builds) or it is malformed.
    static func pin(besideCLI cli: URL) -> Pin? {
        let manifest = cli.deletingLastPathComponent().appendingPathComponent("cmux-tui-ssh/manifest.json")
        return (try? Data(contentsOf: manifest)).flatMap(pin(manifest:))
    }

    /// The pin in a `cmux-tui-ssh/manifest.json`: `commit` (40 hex) and the x86_64 Linux binary's
    /// digest (64 hex). Both reach a shell, so anything else is refused.
    static func pin(manifest: Data) -> Pin? {
        struct Manifest: Decodable {
            var commit: String
            var binaries: [String: String]
        }
        guard let manifest = try? JSONDecoder().decode(Manifest.self, from: manifest),
              let sha256 = manifest.binaries["cmux-tui-\(target)"]?.lowercased(),
              isHex(manifest.commit.lowercased(), count: 40), isHex(sha256, count: 64) else { return nil }
        return Pin(commit: manifest.commit.lowercased(), sha256: sha256)
    }

    /// The guest script, from the app's resources.
    static var script: String? {
        Bundle.module.url(forResource: "cmux-tui-upgrade", withExtension: "sh").flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }

    /// Runs the update of a machine through `exec` (one call, the whole run) and answers as
    /// `cmux link machine update` would. An exec that did not answer may have left the run going:
    /// `machine_update_unresolved`, so the policy asks again and the machine reports its build.
    static func run(pin: Pin, script: String, nonce: String = newNonce(),
                    exec: @Sendable (_ command: String, _ timeoutMs: Int) async throws -> CloudExecResult) async -> CloudMoveCLI.Answer {
        do {
            return answer(try await exec(command(pin: pin, script: script, nonce: nonce), timeoutMs), pin: pin)
        } catch {
            return CloudMoveCLI.Answer(ok: false, errorCode: "machine_update_unresolved",
                                       error: "the machine's update did not answer: \(error)")
        }
    }

    /// The exec body: the run's files go to a fresh directory, and the guest script runs as root
    /// in a transient systemd unit the exec waits on (without systemd, under `setsid`). Only the
    /// result line goes to stdout, and the log's tail to stderr.
    static func command(pin: Pin, script: String, nonce: String) -> String {
        let run = "\(directory)/app-\(nonce)"
        let args = "\(pin.sha256) \(pin.commit) \"$r\""
        return [
            "set -eu",
            #"root() { if [ "$(id -u)" = 0 ]; then "$@"; else sudo -n "$@"; fi; }"#,
            // An account that cannot become root cannot run the upgrade: said so, and nothing changed.
            "root true 2>/dev/null || { echo NOROOT; exit 0; }",
            "r=\(run)",
            #"root mkdir -p "$r""#,
            "\(writeFile(installCommand(pin), to: "$r/install.cmd"))",
            "\(writeFile(script, to: "$r/upgrade.sh"))",
            "if command -v systemd-run >/dev/null 2>&1; then root systemd-run --quiet --collect --wait --unit=cmux-app-tui-update-\(nonce) /bin/sh \"$r/upgrade.sh\" \(args) >/dev/null 2>&1 || true; fi",
            // No unit ran it (no systemd, or it would not start): the script never wrote its result.
            #"if [ ! -s "$r/result" ]; then root setsid nohup sh "$r/upgrade.sh" \#(args) </dev/null >/dev/null 2>&1 & wait $! || true; fi"#,
            #"line=$(root cat "$r/result" 2>/dev/null || true); root tail -n 15 "$r/log" >&2 2>/dev/null || true"#,
            // The backup is the rollback's only; a run that ended well needs it no longer.
            #"case "$line" in OK*|UNVERIFIED*) root rm -f "$r/cmux-tui.prev" ;; esac"#,
            #"printf '%s\n' "$line""#,
        ].joined(separator: "\n")
    }

    /// The pinned install the guest script runs as root (`install.cmd`): the daemon's own layout
    /// (`cmuxTuiLayoutSelector` in web/services/vms/drivers/cmuxTuiDaemon.ts), the pinned binary
    /// downloaded and checked beside it, then renamed over it. A binary that already matches the
    /// pin stays.
    static func installCommand(_ pin: Pin) -> String {
        let check = { (file: String) in "printf '%s  %s\\n' \(pin.sha256) \"\(file)\" | sha256sum -c >/dev/null 2>&1" }
        return [
            "set -eu",
            "if id -u cmux >/dev/null 2>&1 && command -v setpriv >/dev/null 2>&1 && setpriv --reuid=cmux --regid=cmux --init-groups test -w /home/cmux 2>/dev/null && setpriv --reuid=cmux --regid=cmux --init-groups sudo -n true >/dev/null 2>&1; then u=cmux; h=/home/cmux; else u=root; h=/root; fi",
            #"bin="$h/.cmux/bin/cmux-tui"; tmp="$bin.app-update""#,
            "if [ -x \"$bin\" ] && \(check("$bin")); then :; else",
            "  curl -fsSL --retry 3 -o \"$tmp\" '\(pin.url)' && \(check("$tmp")) || { rm -f \"$tmp\"; echo 'the pinned build did not download or match its pin' >&2; exit 1; }",
            #"  chmod 755 "$tmp"; [ "$u" = root ] || chown "$u:$u" "$tmp"; mv -f "$tmp" "$bin""#,
            "fi",
            #"ln -sfn "$bin" /usr/local/bin/cmux-tui"#,
            #""$bin" --version"#,
        ].joined(separator: "\n") + "\n"
    }

    /// The guest script's result line as a `link machine update` answer.
    static func answer(_ ran: CloudExecResult, pin: Pin) -> CloudMoveCLI.Answer {
        let line = ran.stdout.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
        let detail = line.isEmpty ? String(ran.stderr.suffix(400)) : line
        func failed(_ code: String) -> CloudMoveCLI.Answer { CloudMoveCLI.Answer(ok: false, errorCode: code, error: detail) }
        switch line.split(separator: " ").first.map(String.init) ?? "" {
        // UNVERIFIED: the new daemon serves and kept every host; only the terminal count was unreadable.
        case "OK", "UNVERIFIED":
            return CloudMoveCLI.Answer(ok: true, updated: true, build: pin.commit)
        case "ROLLBACK":
            return failed("machine_update_rolled_back")
        case "FAIL":
            return failed("machine_update_failed")
        case "NOROOT":
            return failed("machine_update_unsupported")
        case "SKIP":
            if line.hasPrefix("SKIP busy") { return failed("machine_update_busy") }
            // Between restarts of a crash-looping daemon: ask again later.
            if line.hasPrefix("SKIP no-daemon") { return failed("machine_unreachable") }
            // A daemon the fleet upgrade does not replace (no trusted carrier): not this way.
            if line.hasPrefix("SKIP unsupported-cloud-auth") { return failed("machine_update_unsupported") }
            return failed("machine_update_failed")
        default:
            // The command stopped before the run (it wrote nothing): nothing changed.
            if line.isEmpty && ran.exitCode != 0 { return failed("machine_update_failed") }
            // No result yet: the run did not end within the exec, or reports no outcome.
            if line.isEmpty || line == "running" || line == "PENDING" { return failed("machine_update_unresolved") }
            return failed("machine_update_failed")
        }
    }

    /// 16 hex characters: names the run's directory and unit.
    static func newNonce() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(16))
    }

    /// `echo BASE64 | base64 -d | root tee FILE`: the exec body carries no quoting of its own.
    private static func writeFile(_ contents: String, to file: String) -> String {
        "echo \(Data(contents.utf8).base64EncodedString()) | base64 -d | root tee \"\(file)\" >/dev/null"
    }

    private static func isHex(_ text: String, count: Int) -> Bool {
        text.count == count && text.allSatisfy { $0.isHexDigit && ($0.isNumber || $0.isLowercase) }
    }
}
