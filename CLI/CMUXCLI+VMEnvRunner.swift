import Foundation

/// In-VM script transport for `cmux vm env build`.
///
/// Each step is submitted as one bounded `vm.exec` operation. The provider
/// owns the process and timeout, so completion and output come from the same
/// authoritative operation that runs the command.
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
            } catch let error as CLIError where error.isStructuredProtocolResponse && !error.v2Retryable {
                throw error
            } catch {
                lastError = error
            }
        }
        throw lastError ?? CLIError(message: "vm env: exec failed")
    }

    struct VMEnvScriptOutcome {
        let status: String // ok | failed | timeout | lost
        let exitCode: Int?
        let logTail: String?
    }

    /// Writes the requested step/verify scripts into the VM. Callers stage each
    /// script just before it runs, so a layer snapshot taken after step i
    /// contains only the scripts for steps 0...i.
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
        var files: [(name: String, content: String)] = []
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
        writes.append("chmod 755 \(Self.vmEnvDir)/*.sh")
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

    /// Runs a staged script through the provider-owned VM operation.
    func vmEnvRunScript(
        vmId: String,
        scriptId: String,
        timeoutMinutes: Int,
        client: SocketClient
    ) throws -> VMEnvScriptOutcome {
        let response = try vmEnvExec(
            vmId: vmId,
            command: "bash -l \(Self.vmEnvDir)/\(scriptId).sh",
            timeoutMs: max(1, timeoutMinutes) * 60_000,
            responseTimeout: TimeInterval(max(1, timeoutMinutes) * 60 + 60),
            client: client
        )
        let exitCode = (response["exit_code"] as? Int) ?? -1
        let stdout = response["stdout"] as? String ?? ""
        let stderr = response["stderr"] as? String ?? ""
        let logTail = [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n")
        return VMEnvScriptOutcome(status: exitCode == 0 ? "ok" : "failed", exitCode: exitCode, logTail: logTail.isEmpty ? nil : logTail)
    }

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
