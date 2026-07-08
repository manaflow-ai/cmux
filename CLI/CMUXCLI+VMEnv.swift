import Darwin
import Foundation

/// `cmux vm env` — declarative environment setup with layer-cached snapshots.
///
/// Each step in `.cmux/env.yaml` runs inside a Cloud VM; after a step succeeds
/// the VM is snapshotted and the snapshot registered under the step's chain
/// hash. Later builds restore the deepest cached layer (~1s on Freestyle) and
/// run only the remaining steps. Long steps run through a small runner script
/// inside the VM (started detached, polled with short execs) because a single
/// `vm.exec` cannot outlive the backend's request window.
extension CMUXCLI {
    private static let vmEnvDir = "/var/tmp/cmux-env"
    private static let vmEnvLongOpTimeout: TimeInterval = 16 * 60
    private static let vmEnvPollIntervalSeconds: UInt32 = 2
    private static let vmEnvDefaultStepTimeoutMinutes = 30

    func runVMEnvCommand(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        windowId: String?,
        idFormat: CLIIDFormat
    ) throws {
        let sub = commandArgs.first?.lowercased() ?? "help"
        let rest = Array(commandArgs.dropFirst())
        switch sub {
        case "build":
            try runVMEnvBuild(args: rest, client: client, jsonOutput: jsonOutput)
        case "up":
            try runVMEnvUp(args: rest, client: client, jsonOutput: jsonOutput, windowId: windowId, idFormat: idFormat)
        case "init":
            try runVMEnvInit(args: rest, jsonOutput: jsonOutput)
        case "layers":
            try runVMEnvLayers(args: rest, client: client, jsonOutput: jsonOutput)
        case "logs":
            try runVMEnvLogs(args: rest, client: client, jsonOutput: jsonOutput)
        default:
            throw CLIError(message: """
                Usage: cmux vm env <build|up|init|layers|logs> [args...]

                  cmux vm env init [--goal "<text>"]     scaffold .cmux/env.yaml
                  cmux vm env build [--spec <path>] [--json] [--no-cache]
                  cmux vm env up [--spec <path>] [--window <id>] [--detach|-d]
                  cmux vm env layers [--json]
                  cmux vm env logs <vm-id> --step <n>

                A build runs each spec step in a Cloud VM, snapshots after each
                success, and caches the snapshot per step. Re-builds restore the
                deepest cached layer and only run what changed.
                """)
        }
    }

    // MARK: - Spec loading

    private struct VMEnvLoadedSpec {
        let path: String
        let text: String
        let spec: VMEnvSpec
        let digest: String
    }

    private func vmEnvLoadSpec(args: [String]) throws -> (spec: VMEnvLoadedSpec, remaining: [String]) {
        let (specOpt, remaining) = parseOption(args, name: "--spec")
        let path: String
        if let specOpt {
            path = (specOpt as NSString).expandingTildeInPath
        } else if let found = Self.vmEnvFindSpecUpward(from: FileManager.default.currentDirectoryPath) {
            path = found
        } else {
            throw CLIError(message: """
                No .cmux/env.yaml found here or in any parent directory.

                Create one:
                  cmux vm env init
                Or point at one:
                  cmux vm env build --spec path/to/env.yaml
                """)
        }
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8) else {
            throw CLIError(message: "Could not read spec at \(path)")
        }
        let spec: VMEnvSpec
        do {
            spec = try VMEnvSpecCodec.parse(text)
        } catch let err as VMEnvSpecParseError {
            throw CLIError(message: "Invalid env spec at \(path)\n  \(err.description)")
        }
        return (VMEnvLoadedSpec(path: path, text: text, spec: spec, digest: VMEnvSpecCodec.specDigest(text)), remaining)
    }

    static func vmEnvFindSpecUpward(from directory: String) -> String? {
        var dir = URL(fileURLWithPath: directory)
        for _ in 0..<32 {
            let candidate = dir.appendingPathComponent(".cmux/env.yaml").path
            if FileManager.default.fileExists(atPath: candidate) { return candidate }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return nil
    }

    // MARK: - build

    private struct VMEnvStepReport {
        let index: Int
        let name: String
        var status: String
        var exitCode: Int?
        var durationMs: Int?
        var snapshotId: String?
        var chainHash: String
        var logTail: String?

        var payload: [String: Any] {
            [
                "index": index,
                "name": name,
                "status": status,
                "exitCode": exitCode ?? NSNull(),
                "durationMs": durationMs ?? NSNull(),
                "snapshotId": snapshotId ?? NSNull(),
                "chainHash": chainHash,
                "logTail": logTail ?? NSNull(),
            ]
        }
    }

    private func runVMEnvBuild(args: [String], client: SocketClient, jsonOutput: Bool) throws {
        let (loaded, afterSpec) = try vmEnvLoadSpec(args: args)
        let noCache = hasFlag(afterSpec, name: "--no-cache")
        let spec = loaded.spec

        // Resolve the provider + base image the server would boot so chain
        // hashes are computed against the deployed image id.
        let resolveEmpty = try client.sendV2(
            method: "vm.env_resolve_layers",
            params: ["chain_hashes": [String]()],
            responseTimeout: 60
        )
        guard let provider = resolveEmpty["provider"] as? String,
              let defaultBaseImage = resolveEmpty["base_image_id"] as? String else {
            throw CLIError(message: "vm env build: backend did not return a provider/base image. Update the cmux app and try again.")
        }
        let baseImageId: String
        let usesCustomBase: Bool
        if let base = spec.base, !base.isEmpty, base.lowercased() != "default" {
            baseImageId = base
            usesCustomBase = true
        } else {
            baseImageId = defaultBaseImage
            usesCustomBase = false
        }

        let chainHashes = VMEnvSpecCodec.chainHashes(provider: provider, baseImageId: baseImageId, spec: spec)

        var cachedLayerIndex = -1
        var restoredSnapshotId: String?
        if !noCache {
            let resolve = try client.sendV2(
                method: "vm.env_resolve_layers",
                params: ["provider": provider, "chain_hashes": chainHashes],
                responseTimeout: 60
            )
            if let layer = resolve["layer"] as? [String: Any],
               let stepIndex = layer["step_index"] as? Int,
               let snapshotId = layer["snapshot_id"] as? String,
               stepIndex >= 0, stepIndex < spec.steps.count {
                cachedLayerIndex = stepIndex
                restoredSnapshotId = snapshotId
            }
        }

        var reports: [VMEnvStepReport] = spec.steps.enumerated().map { index, step in
            VMEnvStepReport(
                index: index,
                name: step.name,
                status: index <= cachedLayerIndex ? "cached" : "pending",
                exitCode: nil,
                durationMs: nil,
                snapshotId: nil,
                chainHash: chainHashes[index]
            )
        }
        let startIndex = cachedLayerIndex + 1

        if !jsonOutput {
            print("env: \(spec.name ?? loaded.path)")
            print("provider: \(provider)  base: \(baseImageId)")
            if cachedLayerIndex >= 0 {
                print("cache: layers 0-\(cachedLayerIndex) cached (\(spec.steps.count - startIndex) of \(spec.steps.count) steps to run)")
            } else {
                print("cache: no cached layers (\(spec.steps.count) steps to run)")
            }
        }

        // Boot the VM: restore the deepest cached layer, or create from base.
        let restoreStartedAt = Date()
        let vmId: String
        if let snapshotId = restoredSnapshotId {
            let response = try client.sendV2(
                method: "vm.restore",
                params: [
                    "snapshot_id": snapshotId,
                    "provider": provider,
                    "idempotency_key": UUID().uuidString.lowercased(),
                ],
                responseTimeout: Self.vmEnvLongOpTimeout
            )
            guard let id = response["id"] as? String, !id.isEmpty else {
                throw CLIError(message: "vm env build: restore of cached layer returned no VM id")
            }
            vmId = id
        } else {
            var params: [String: Any] = [
                "provider": provider,
                "idempotency_key": UUID().uuidString.lowercased(),
            ]
            if usesCustomBase { params["image"] = baseImageId }
            let response = try client.sendV2(
                method: "vm.create",
                params: params,
                responseTimeout: Self.vmEnvLongOpTimeout
            )
            guard let id = response["id"] as? String, !id.isEmpty else {
                throw CLIError(message: "vm env build: VM create returned no id")
            }
            vmId = id
        }
        let restoreMs = Int(Date().timeIntervalSince(restoreStartedAt) * 1000)
        if !jsonOutput {
            print(restoredSnapshotId != nil
                ? "restored cached layer into VM \(vmId) (\(restoreMs)ms)"
                : "created VM \(vmId) (\(restoreMs)ms)")
        }

        // Ship the runner + remaining step/verify scripts in one exec.
        try vmEnvShipScripts(
            vmId: vmId,
            spec: spec,
            stepIndices: Array(startIndex..<spec.steps.count),
            client: client
        )

        var failingStepIndex: Int?
        var failureKind: String?

        for index in startIndex..<spec.steps.count {
            let step = spec.steps[index]
            if !jsonOutput { print("step \(index) [\(step.name)] running...") }
            let started = Date()
            let outcome = try vmEnvRunScript(
                vmId: vmId,
                scriptId: "step-\(index)",
                timeoutMinutes: step.timeoutMinutes ?? Self.vmEnvDefaultStepTimeoutMinutes,
                client: client
            )
            reports[index].durationMs = Int(Date().timeIntervalSince(started) * 1000)
            reports[index].exitCode = outcome.exitCode
            reports[index].logTail = outcome.logTail
            if outcome.status == "ok" {
                // Snapshot the successful layer and register it in the cache.
                let snapshotResponse = try client.sendV2(
                    method: "vm.snapshot",
                    params: ["id": vmId, "name": "env-\(String(loaded.digest.prefix(12)))-step-\(index)"],
                    responseTimeout: Self.vmEnvLongOpTimeout
                )
                let snapshotId = (snapshotResponse["snapshot_id"] as? String) ?? (snapshotResponse["id"] as? String)
                if let snapshotId, !snapshotId.isEmpty {
                    reports[index].snapshotId = snapshotId
                    _ = try client.sendV2(
                        method: "vm.env_record_layer",
                        params: [
                            "provider": provider,
                            "base_image_id": baseImageId,
                            "chain_hash": chainHashes[index],
                            "step_index": index,
                            "step_name": step.name,
                            "spec_digest": loaded.digest,
                            "snapshot_id": snapshotId,
                        ],
                        responseTimeout: 60
                    )
                }
                reports[index].status = "ok"
                if !jsonOutput { print("step \(index) [\(step.name)] ok (\(reports[index].durationMs ?? 0)ms, layer cached)") }
            } else {
                reports[index].status = outcome.status
                failingStepIndex = index
                failureKind = outcome.status
                for later in (index + 1)..<spec.steps.count {
                    reports[later].status = "skipped"
                }
                if !jsonOutput {
                    print("step \(index) [\(step.name)] \(outcome.status) (exit \(outcome.exitCode.map(String.init) ?? "-"))")
                    if let tail = outcome.logTail, !tail.isEmpty {
                        print("--- log tail ---")
                        print(tail)
                        print("----------------")
                    }
                }
            }
            if failingStepIndex != nil { break }
        }

        // Verify commands always run (never cached, never snapshotted).
        var verifyReports: [[String: Any]] = []
        if failingStepIndex == nil {
            for (index, _) in spec.verify.enumerated() {
                if !jsonOutput { print("verify \(index) running...") }
                let started = Date()
                let outcome = try vmEnvRunScript(
                    vmId: vmId,
                    scriptId: "verify-\(index)",
                    timeoutMinutes: Self.vmEnvDefaultStepTimeoutMinutes,
                    client: client
                )
                verifyReports.append([
                    "index": index,
                    "status": outcome.status,
                    "exitCode": outcome.exitCode ?? NSNull(),
                    "durationMs": Int(Date().timeIntervalSince(started) * 1000),
                    "logTail": outcome.logTail ?? NSNull(),
                ])
                if outcome.status != "ok" {
                    failingStepIndex = spec.steps.count + index
                    failureKind = "verify_failed"
                    if !jsonOutput {
                        print("verify \(index) \(outcome.status) (exit \(outcome.exitCode.map(String.init) ?? "-"))")
                        if let tail = outcome.logTail, !tail.isEmpty {
                            print("--- log tail ---")
                            print(tail)
                            print("----------------")
                        }
                    }
                    break
                }
                if !jsonOutput { print("verify \(index) ok") }
            }
        }

        let ok = failingStepIndex == nil
        let report: [String: Any] = [
            "ok": ok,
            "specPath": loaded.path,
            "specDigest": loaded.digest,
            "provider": provider,
            "baseImageId": baseImageId,
            "vmId": vmId,
            "cache": [
                "deepestCachedStepIndex": cachedLayerIndex >= 0 ? cachedLayerIndex : NSNull(),
                "restoredSnapshotId": restoredSnapshotId ?? NSNull(),
                "restoreMs": restoreMs,
            ] as [String: Any],
            "steps": reports.map(\.payload),
            "verify": verifyReports,
            "failingStepIndex": failingStepIndex ?? NSNull(),
            "error": failureKind ?? NSNull(),
            "hint": ok
                ? "All layers cached. `cmux vm env up` now boots this environment in seconds."
                : "Fix the failing step in the spec and re-run `cmux vm env build`; cached layers before it will not re-run. Inspect with `cmux vm env logs \(vmId) --step \(failingStepIndex ?? 0)` or `cmux vm exec \(vmId) -- <cmd>`.",
        ]
        if jsonOutput {
            print(jsonString(report))
        } else if ok {
            print("OK env build complete (\(spec.steps.count) layers cached). VM \(vmId) left running.")
            print("Next: cmux vm env up")
        }
        if !ok {
            throw CLIError(message: "env build failed at \(failingStepIndex.map { $0 < spec.steps.count ? "step \($0)" : "verify \($0 - spec.steps.count)" } ?? "?"). VM \(vmId) left running for inspection.")
        }
    }

    // MARK: - In-VM script transport

    /// `vm.exec` with bounded retries. Provider exec blips (Freestyle has
    /// returned transient 502 `provider_internal` on fresh VMs) are marked
    /// retryable by the backend; a multi-minute build should ride them out
    /// instead of aborting.
    private func vmEnvExec(
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

    private struct VMEnvScriptOutcome {
        let status: String // ok | failed | timeout | lost
        let exitCode: Int?
        let logTail: String?
    }

    /// Writes the runner plus every needed step/verify script into the VM with
    /// a single exec. Scripts are base64-encoded so arbitrary step text never
    /// needs shell quoting.
    private func vmEnvShipScripts(
        vmId: String,
        spec: VMEnvSpec,
        stepIndices: [Int],
        client: SocketClient
    ) throws {
        var files: [(name: String, content: String)] = [("runner.sh", Self.vmEnvRunnerScript)]
        for index in stepIndices {
            files.append(("step-\(index).sh", Self.vmEnvStepScript(run: spec.steps[index].run, env: spec.env)))
        }
        for (index, run) in spec.verify.enumerated() {
            files.append(("verify-\(index).sh", Self.vmEnvStepScript(run: run, env: spec.env)))
        }
        var commands = ["set -e", "mkdir -p \(Self.vmEnvDir)", "umask 022"]
        for file in files {
            let encoded = Data(file.content.utf8).base64EncodedString()
            commands.append("printf '%s' '\(encoded)' | base64 -d > \(Self.vmEnvDir)/\(file.name)")
        }
        commands.append("chmod 755 \(Self.vmEnvDir)/runner.sh")
        let response = try vmEnvExec(
            vmId: vmId,
            command: commands.joined(separator: "; "),
            timeoutMs: 60_000,
            responseTimeout: 90,
            client: client
        )
        let exitCode = (response["exit_code"] as? Int) ?? -1
        if exitCode != 0 {
            let stderr = (response["stderr"] as? String) ?? ""
            throw CLIError(message: "vm env build: failed to stage scripts in VM \(vmId) (exit \(exitCode)): \(stderr)")
        }
    }

    /// Starts a staged script detached inside the VM, then polls its status
    /// file every couple of seconds. Every network call stays short; the step
    /// itself can run for minutes.
    private func vmEnvRunScript(
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

    // MARK: - up

    private func runVMEnvUp(
        args: [String],
        client: SocketClient,
        jsonOutput: Bool,
        windowId: String?,
        idFormat: CLIIDFormat
    ) throws {
        let (loaded, afterSpec) = try vmEnvLoadSpec(args: args)
        let (windowOpt, afterWindow) = parseOption(afterSpec, name: "--window")
        let detach = hasFlag(afterWindow, name: "--detach") || hasFlag(afterWindow, name: "-d")
        let spec = loaded.spec

        let resolveEmpty = try client.sendV2(
            method: "vm.env_resolve_layers",
            params: ["chain_hashes": [String]()],
            responseTimeout: 60
        )
        guard let provider = resolveEmpty["provider"] as? String,
              let defaultBaseImage = resolveEmpty["base_image_id"] as? String else {
            throw CLIError(message: "vm env up: backend did not return a provider/base image.")
        }
        let baseImageId = (spec.base?.isEmpty == false && spec.base?.lowercased() != "default") ? spec.base! : defaultBaseImage
        let chainHashes = VMEnvSpecCodec.chainHashes(provider: provider, baseImageId: baseImageId, spec: spec)
        let resolve = try client.sendV2(
            method: "vm.env_resolve_layers",
            params: ["provider": provider, "chain_hashes": chainHashes],
            responseTimeout: 60
        )
        guard let layer = resolve["layer"] as? [String: Any],
              let stepIndex = layer["step_index"] as? Int,
              let snapshotId = layer["snapshot_id"] as? String,
              stepIndex == spec.steps.count - 1 else {
            throw CLIError(message: """
                This spec is not fully cached yet (or changed since the last build).

                Run:
                  cmux vm env build
                """)
        }

        let response = try client.sendV2(
            method: "vm.restore",
            params: [
                "snapshot_id": snapshotId,
                "provider": provider,
                "idempotency_key": UUID().uuidString.lowercased(),
            ],
            responseTimeout: Self.vmEnvLongOpTimeout
        )
        guard let vmId = response["id"] as? String, !vmId.isEmpty else {
            throw CLIError(message: "vm env up: restore returned no VM id")
        }
        if jsonOutput {
            print(jsonString(["ok": true, "vmId": vmId, "snapshotId": snapshotId, "provider": provider]))
            return
        }
        print("Restored environment into VM \(vmId)")
        if detach {
            print("Attach: cmux vm shell \(vmId)")
            return
        }
        let workspaceName = spec.name.map { "env:\($0)" } ?? "env:\(String(vmId.prefix(8)))"
        try vmOpenShell(
            id: vmId,
            workspaceName: workspaceName,
            windowRaw: windowOpt ?? windowId,
            forceSSH: false,
            shouldPinWorkspaceToTop: false,
            client: client,
            jsonOutput: jsonOutput,
            idFormat: idFormat
        )
    }

    // MARK: - init

    private func runVMEnvInit(args: [String], jsonOutput: Bool) throws {
        let (goalOpt, _) = parseOption(args, name: "--goal")
        let path = ".cmux/env.yaml"
        if FileManager.default.fileExists(atPath: path) {
            throw CLIError(message: "\(path) already exists. Edit it, then run `cmux vm env build`.")
        }
        try FileManager.default.createDirectory(atPath: ".cmux", withIntermediateDirectories: true)
        let goalComment = goalOpt.map { "# Goal: \($0)\n" } ?? ""
        let template = """
        \(goalComment)# cmux Cloud VM environment spec. Each step becomes a cached snapshot layer:
        # edit a step and only that layer (and later ones) re-run on the next build.
        version: 1
        name: my-project
        steps:
          - name: system packages
            run: sudo apt-get update && sudo apt-get install -y build-essential
          - name: clone
            run: |
              git clone https://github.com/OWNER/REPO
        verify:
          - run: test -d REPO
        """
        try (template + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        if jsonOutput {
            print(jsonString(["ok": true, "path": path]))
        } else {
            print("Wrote \(path). Edit the steps, then: cmux vm env build")
        }
    }

    // MARK: - layers

    private func runVMEnvLayers(args: [String], client: SocketClient, jsonOutput: Bool) throws {
        var params: [String: Any] = [:]
        if let found = Self.vmEnvFindSpecUpward(from: FileManager.default.currentDirectoryPath),
           let data = FileManager.default.contents(atPath: found),
           let text = String(data: data, encoding: .utf8),
           !hasFlag(args, name: "--all") {
            params["spec_digest"] = VMEnvSpecCodec.specDigest(text)
        }
        let response = try client.sendV2(method: "vm.env_list_layers", params: params, responseTimeout: 60)
        if jsonOutput {
            print(jsonString(response))
            return
        }
        let layers = (response["layers"] as? [[String: Any]]) ?? []
        if layers.isEmpty {
            print("No cached env layers. Run `cmux vm env build` (or pass --all to list every spec's layers).")
            return
        }
        for layer in layers {
            let index = (layer["step_index"] as? Int) ?? -1
            let name = (layer["step_name"] as? String) ?? "?"
            let snapshot = (layer["snapshot_id"] as? String) ?? "?"
            let hash = (layer["chain_hash"] as? String) ?? "?"
            print("layer \(index)  \(name)  snapshot=\(snapshot)  chain=\(String(hash.prefix(12)))")
        }
    }

    // MARK: - logs

    private func runVMEnvLogs(args: [String], client: SocketClient, jsonOutput: Bool) throws {
        let (stepOpt, remaining) = parseOption(args, name: "--step")
        guard let vmId = remaining.first else {
            throw CLIError(message: "Usage: cmux vm env logs <vm-id> [--step <n>]")
        }
        let command: String
        if let stepOpt {
            command = "tail -c 65536 \(Self.vmEnvDir)/step-\(stepOpt).log 2>/dev/null || echo 'no log for step \(stepOpt)'"
        } else {
            command = "ls -la \(Self.vmEnvDir) 2>/dev/null && for f in \(Self.vmEnvDir)/*.log; do echo \"== $f\"; tail -c 4096 \"$f\"; done"
        }
        let response = try client.sendV2(
            method: "vm.exec",
            params: ["id": vmId, "command": command, "timeout_ms": 20_000],
            responseTimeout: 40
        )
        if jsonOutput {
            print(jsonString(response))
            return
        }
        print((response["stdout"] as? String) ?? "")
    }
}
