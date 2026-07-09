import Darwin
import Foundation

/// In-VM script transport for `cmux vm env build`.
///
/// Steps run through a small POSIX-sh runner staged inside the VM: `start`
/// launches the step detached in its own session, `poll` reports status plus a
/// base64 log tail, `kill` handles client-side timeouts. This keeps every
/// `vm.exec` short even when a step runs for minutes.
extension CMUXCLI {
    // MARK: - In-VM script transport

    /// `vm.exec` with bounded retries. Provider exec blips (Freestyle has
    /// returned transient 502 `provider_internal` on fresh VMs) are marked
    /// retryable by the backend; a multi-minute build should ride them out
    /// instead of aborting.
    func vmEnvExec(
        vmId: String,
        command: String,
        timeoutMs: Int,
        responseTimeout: TimeInterval,
        client: SocketClient,
        attempts: Int = 4
    ) throws -> [String: Any] {
        var lastError: Error?
        for attempt in 0..<attempts {
            do {
                return try client.sendV2(
                    method: "vm.exec",
                    params: ["id": vmId, "command": command, "timeout_ms": timeoutMs],
                    responseTimeout: responseTimeout
                )
            } catch {
                lastError = error
                if attempt < attempts - 1 { sleep(3) }
            }
        }
        throw lastError ?? CLIError(message: "vm env: exec failed")
    }

    struct VMEnvScriptOutcome {
        let status: String // ok | failed | timeout | lost
        let exitCode: Int?
        let logTail: String?
    }

    /// Writes the runner plus the requested step/verify scripts into the VM.
    /// Callers stage each script just before it runs, so a layer snapshot
    /// taken after step i contains only the scripts for steps 0...i (never
    /// future step or verify text, which is outside that layer's cache key).
    /// Scripts are base64-encoded so arbitrary step text never needs shell
    /// quoting, sliced so no single write outgrows shell/provider command
    /// limits, and packed into as few execs as those limits allow.
    func vmEnvShipScripts(
        vmId: String,
        spec: VMEnvSpec,
        stepIndices: [Int],
        includeVerify: Bool,
        client: SocketClient
    ) throws {
        var files: [(name: String, content: String)] = [("runner.sh", Self.vmEnvRunnerScript)]
        for index in stepIndices {
            files.append(("step-\(index).sh", Self.vmEnvStepScript(run: spec.steps[index].run, env: spec.env)))
        }
        if includeVerify {
            for (index, run) in spec.verify.enumerated() {
                files.append(("verify-\(index).sh", Self.vmEnvStepScript(run: run, env: spec.env)))
            }
        }
        // 45KB of source bytes -> ~60KB of base64 per write; well under the
        // conservative ~128KB command-length floor across providers. Every
        // command is idempotent (`rm -f`, `>` truncates, concat re-reads all
        // parts) so a lost-response retry of any exec cannot corrupt a staged
        // script.
        let sliceBytes = 45_000
        let maxCommandBytes = 90_000
        var writes: [String] = []
        for file in files {
            let path = "\(Self.vmEnvDir)/\(file.name)"
            if file.name.hasSuffix(".sh"), file.name != "runner.sh" {
                // Restored snapshots carry the previous build's runner state;
                // scrub this script's exit/pid/log (and stale slices) so the
                // idempotent `runner.sh start` guard never mistakes an old
                // run's exit file for this build's result. Staging always
                // completes before any start, so in-build retry idempotency
                // is preserved.
                let id = String(file.name.dropLast(3))
                writes.append("rm -f \(Self.vmEnvDir)/\(id).exit \(Self.vmEnvDir)/\(id).pid \(Self.vmEnvDir)/\(id).log \(path).slice-*")
            }
            let data = Data(file.content.utf8)
            if data.count <= sliceBytes {
                writes.append("printf '%s' '\(data.base64EncodedString())' | base64 -d > \(path)")
                continue
            }
            var offset = 0
            var slice = 0
            while offset < data.count {
                let chunk = data.subdata(in: offset..<min(offset + sliceBytes, data.count))
                let part = String(format: "%@.slice-%03d", file.name, slice)
                writes.append("printf '%s' '\(chunk.base64EncodedString())' | base64 -d > \(Self.vmEnvDir)/\(part)")
                offset += sliceBytes
                slice += 1
            }
            writes.append("cat \(path).slice-* > \(path)")
        }
        writes.append("chmod 755 \(Self.vmEnvDir)/runner.sh")

        let prologue = "set -e; umask 022; mkdir -p \(Self.vmEnvDir)"
        var batch: [String] = [prologue]
        var batchBytes = prologue.utf8.count
        func flush() throws {
            guard batch.count > 1 else { return }
            let response = try vmEnvExec(
                vmId: vmId,
                command: batch.joined(separator: "; "),
                timeoutMs: 60_000,
                responseTimeout: 90,
                client: client
            )
            let exitCode = (response["exit_code"] as? Int) ?? -1
            if exitCode != 0 {
                let stderr = (response["stderr"] as? String) ?? ""
                throw CLIError(message: "vm env build: failed to stage scripts in VM \(vmId) (exit \(exitCode)): \(stderr)")
            }
            batch = [prologue]
            batchBytes = prologue.utf8.count
        }
        for write in writes {
            if batchBytes + write.utf8.count + 2 > maxCommandBytes { try flush() }
            batch.append(write)
            batchBytes += write.utf8.count + 2
        }
        try flush()
    }

    /// Starts a staged script detached inside the VM, then polls its status
    /// file every couple of seconds. Every network call stays short; the step
    /// itself can run for minutes.
    func vmEnvRunScript(
        vmId: String,
        scriptId: String,
        timeoutMinutes: Int,
        client: SocketClient
    ) throws -> VMEnvScriptOutcome {
        let start = try vmEnvExec(
            vmId: vmId,
            command: "sh \(Self.vmEnvDir)/runner.sh start \(scriptId)",
            timeoutMs: 30_000,
            responseTimeout: 45,
            client: client
        )
        if ((start["exit_code"] as? Int) ?? -1) != 0 {
            let stderr = (start["stderr"] as? String) ?? ""
            throw CLIError(message: "vm env build: could not start \(scriptId) in VM \(vmId): \(stderr)")
        }
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutMinutes) * 60)
        var lostPolls = 0
        while true {
            sleep(Self.vmEnvPollIntervalSeconds)
            let poll = try vmEnvExec(
                vmId: vmId,
                command: "sh \(Self.vmEnvDir)/runner.sh poll \(scriptId)",
                timeoutMs: 20_000,
                responseTimeout: 40,
                client: client
            )
            let stdout = (poll["stdout"] as? String) ?? ""
            let parsed = Self.vmEnvParsePoll(stdout)
            switch parsed.state {
            case "exited":
                let exitCode = parsed.exitCode ?? -1
                return VMEnvScriptOutcome(status: exitCode == 0 ? "ok" : "failed", exitCode: exitCode, logTail: parsed.logTail)
            case "running":
                lostPolls = 0
            default:
                // Status files can be momentarily absent between start and the
                // first write; only give up after repeated losses.
                lostPolls += 1
                if lostPolls >= 5 {
                    return VMEnvScriptOutcome(status: "lost", exitCode: nil, logTail: parsed.logTail)
                }
            }
            if Date() > deadline {
                _ = try? vmEnvExec(
                    vmId: vmId,
                    command: "sh \(Self.vmEnvDir)/runner.sh kill \(scriptId)",
                    timeoutMs: 15_000,
                    responseTimeout: 30,
                    client: client,
                    attempts: 2
                )
                return VMEnvScriptOutcome(status: "timeout", exitCode: nil, logTail: parsed.logTail)
            }
        }
    }

    static func vmEnvParsePoll(_ stdout: String) -> (state: String, exitCode: Int?, logTail: String?) {
        var state = "lost"
        var exitCode: Int?
        var logTail: String?
        for line in stdout.components(separatedBy: "\n") {
            if line.hasPrefix("CMUX_ENV_STATE=") {
                state = String(line.dropFirst("CMUX_ENV_STATE=".count))
            } else if line.hasPrefix("CMUX_ENV_EXIT=") {
                exitCode = Int(line.dropFirst("CMUX_ENV_EXIT=".count))
            } else if line.hasPrefix("CMUX_ENV_LOG64=") {
                let encoded = String(line.dropFirst("CMUX_ENV_LOG64=".count))
                if let data = Data(base64Encoded: encoded), let text = String(data: data, encoding: .utf8) {
                    logTail = text
                }
            }
        }
        return (state, exitCode, logTail)
    }

    /// POSIX-sh runner staged at /var/tmp/cmux-env/runner.sh inside the VM.
    /// `start` launches a staged script in its own session (so it survives the
    /// exec that started it and can be killed as a group); `poll` reports a
    /// machine-parseable status plus a base64 log tail; `kill` terminates the
    /// session on client-side timeout.
    static let vmEnvRunnerScript = """
    #!/bin/sh
    set -u
    DIR=/var/tmp/cmux-env
    cmd=${1:-}
    id=${2:-}
    [ -n "$cmd" ] && [ -n "$id" ] || { echo "usage: runner.sh <start|poll|kill> <script-id>" >&2; exit 2; }
    case "$cmd" in
    start)
      [ -f "$DIR/$id.sh" ] || { echo "missing $DIR/$id.sh" >&2; exit 3; }
      # Idempotent: the client retries a lost exec response, and each script id
      # starts at most once per build, so never relaunch a script that already
      # ran (exit file) or is still running (live pid).
      if [ -f "$DIR/$id.exit" ] || { [ -f "$DIR/$id.pid" ] && kill -0 "$(cat "$DIR/$id.pid")" 2>/dev/null; }; then
        echo "CMUX_ENV_STARTED=$id"
        exit 0
      fi
      rm -f "$DIR/$id.exit" "$DIR/$id.pid"
      : > "$DIR/$id.log"
      setsid sh -c '
        DIR=$1; id=$2
        echo $$ > "$DIR/$id.pid"
        if [ "$(id -u)" = "0" ] && id cmux >/dev/null 2>&1 && command -v runuser >/dev/null 2>&1; then
          runuser -u cmux -- bash -l "$DIR/$id.sh"
        elif [ "$(id -u)" = "0" ] && id cmux >/dev/null 2>&1 && command -v sudo >/dev/null 2>&1; then
          sudo -u cmux -H bash -l "$DIR/$id.sh"
        else
          bash -l "$DIR/$id.sh"
        fi
        rc=$?
        echo "$rc" > "$DIR/$id.exit.tmp" && mv "$DIR/$id.exit.tmp" "$DIR/$id.exit"
      ' sh "$DIR" "$id" >> "$DIR/$id.log" 2>&1 &
      echo "CMUX_ENV_STARTED=$id"
      ;;
    poll)
      if [ -f "$DIR/$id.exit" ]; then
        echo "CMUX_ENV_STATE=exited"
        echo "CMUX_ENV_EXIT=$(cat "$DIR/$id.exit")"
      elif [ -f "$DIR/$id.pid" ] && kill -0 "$(cat "$DIR/$id.pid")" 2>/dev/null; then
        echo "CMUX_ENV_STATE=running"
        echo "CMUX_ENV_EXIT=-"
      else
        echo "CMUX_ENV_STATE=lost"
        echo "CMUX_ENV_EXIT=-"
      fi
      echo "CMUX_ENV_LOG64=$(tail -c 8192 "$DIR/$id.log" 2>/dev/null | base64 | tr -d '\\n')"
      ;;
    kill)
      pid=$(cat "$DIR/$id.pid" 2>/dev/null || true)
      if [ -n "${pid:-}" ]; then
        kill -TERM -- -"$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
      fi
      echo "CMUX_ENV_KILLED=$id"
      ;;
    *)
      echo "unknown runner command: $cmd" >&2
      exit 2
      ;;
    esac
    """

    /// Wraps a spec step's `run` text into an executable bash script with the
    /// spec's env exported. Runs under `bash -l` as user `cmux` so toolchains
    /// installed by earlier layers (mise, cargo, etc.) are on PATH.
    static func vmEnvStepScript(run: String, env: [String: String]) -> String {
        var script = "set -eo pipefail\nexport DEBIAN_FRONTEND=noninteractive\n"
        for key in env.keys.sorted() {
            script += "export \(key)=\(vmEnvShellQuote(env[key] ?? ""))\n"
        }
        script += "cd \"$HOME\"\n"
        script += run
        script += "\n"
        return script
    }

    private static func vmEnvShellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
