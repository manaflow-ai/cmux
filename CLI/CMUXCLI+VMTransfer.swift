import CryptoKit
import Foundation

/// `cmux vm push` / `cmux vm pull` / `cmux vm wait` — file transfer and readiness
/// primitives for cloud machines, built entirely on the existing `vm.exec` and
/// `vm.status` socket methods so they work against every provider that supports
/// exec, with no daemon or SSH requirement on the machine.
///
/// Transfer strategy: files move as base64 chunks inside `vm.exec` commands.
/// Each chunk is one round trip, so throughput is bounded by the exec path, but
/// the primitive works on a machine that only has a shell + coreutils. Both
/// directions verify a SHA-256 digest end to end (falling back to a byte-count
/// check when the machine has no `sha256sum`). Directories travel as tarballs
/// and extract on the far side.
extension CMUXCLI {
    /// Raw bytes per exec round trip. Base64 expands this ~4/3, staying well
    /// under control-plane request/response body limits.
    static let vmTransferChunkBytes = 512 * 1024
    /// Push chunks ride inside the exec command line itself (`printf %s '<b64>'`),
    /// and Linux caps a single argv string at 128 KiB (MAX_ARG_STRLEN): a 512 KiB
    /// chunk base64-encodes to ~700 KB and fails with "argument list too long".
    /// 64 KiB encodes to ~87 KB, comfortably under the cap. Pull is unaffected —
    /// its chunks flow back through stdout, so it keeps the larger size.
    static let vmTransferPushChunkBytes = 64 * 1024
    /// Hard cap for a single push/pull. Exec-chunked transfer is the wrong tool
    /// past this size; the error message points at better tools.
    static let vmTransferMaxBytes = 256 * 1024 * 1024
    static let vmTransferExecTimeoutMs = 100_000
    static let vmTransferExecResponseTimeout: TimeInterval = 120
    /// Directory entries skipped by default on `vm push` of a directory. Every
    /// entry here is cheap to recreate on the machine (installs, build output)
    /// or meaningless there (VCS internals, OS litter); `--no-default-excludes`
    /// sends everything.
    static let vmPushDefaultExcludes = [
        ".git",
        "node_modules",
        ".venv",
        "__pycache__",
        ".DS_Store",
    ]

    static var vmPushUsage: String {
        """
        Usage: cmux vm push <id> <local-path> [remote-path] [--exclude <pattern>]... [--no-default-excludes]

        Copy a local file or directory onto a cloud machine over the exec channel
        (no SSH needed). Directories travel as tarballs; by default \(vmPushDefaultExcludes.joined(separator: ", "))
        are skipped. The remote path defaults to the local basename in the exec
        working directory (the machine user's home).

        Examples:
          cmux vm push brave-otter ./script.sh
          cmux vm push brave-otter ./myrepo work/myrepo
          cmux vm push brave-otter ./site --exclude dist
        """
    }

    static var vmPullUsage: String {
        """
        Usage: cmux vm pull <id> <remote-path> [local-path]

        Copy a file or directory from a cloud machine to the local disk over the
        exec channel. The local path defaults to the remote basename in the
        current directory.

        Examples:
          cmux vm pull brave-otter work/report.pdf
          cmux vm pull brave-otter /var/log/app ./app-logs
        """
    }

    static var vmWaitUsage: String {
        """
        Usage: cmux vm wait <id> [--timeout <seconds>] [--wake]

        Block until the machine reports a ready status (running, ready, standby,
        or paused). --wake additionally runs a trivial exec so a sleeping machine
        is awake when the command returns. Exits non-zero on timeout or when the
        machine reaches a failed state. Default timeout: 180 seconds.
        """
    }

    // MARK: - push

    func runVMPushCommand(rest: [String], client: SocketClient, jsonOutput: Bool, quiet: Bool = false) throws {
        if rest.contains("--help") || rest.contains("-h") {
            print(Self.vmPushUsage)
            return
        }
        var positional: [String] = []
        var extraExcludes: [String] = []
        var useDefaultExcludes = true
        var index = 0
        while index < rest.count {
            let arg = rest[index]
            switch arg {
            case "--exclude":
                guard index + 1 < rest.count else {
                    throw CLIError(message: "--exclude requires a pattern\n\n\(Self.vmPushUsage)")
                }
                extraExcludes.append(rest[index + 1])
                index += 2
            case "--no-default-excludes":
                useDefaultExcludes = false
                index += 1
            default:
                guard !arg.hasPrefix("--") else {
                    throw CLIError(message: "Unknown option \(arg)\n\n\(Self.vmPushUsage)")
                }
                positional.append(arg)
                index += 1
            }
        }
        guard positional.count >= 2, positional.count <= 3 else {
            throw CLIError(message: Self.vmPushUsage)
        }
        let vmID = positional[0]
        let localPath = (positional[1] as NSString).expandingTildeInPath
        let localURL = URL(fileURLWithPath: localPath)

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: localURL.path, isDirectory: &isDirectory) else {
            throw CLIError(message: "No such local path: \(localPath)")
        }

        let started = Date()
        let remotePath = positional.count == 3 ? positional[2] : localURL.lastPathComponent
        let payloadData: Data
        var stagingTarURL: URL?
        var appliedExcludes: [String] = []
        if isDirectory.boolValue {
            let excludes = (useDefaultExcludes ? Self.vmPushDefaultExcludes : []) + extraExcludes
            appliedExcludes = excludes
            let tarURL = try makeLocalTarball(of: localURL, excludes: excludes)
            stagingTarURL = tarURL
            payloadData = try Data(contentsOf: tarURL)
        } else {
            payloadData = try Data(contentsOf: localURL)
        }
        defer {
            if let stagingTarURL {
                try? FileManager.default.removeItem(at: stagingTarURL)
            }
        }
        guard payloadData.count <= Self.vmTransferMaxBytes else {
            throw CLIError(message: """
                \(localPath) is \(Self.formatByteCount(payloadData.count)) after packing; \
                vm push caps out at \(Self.formatByteCount(Self.vmTransferMaxBytes)). \
                For big trees, clone or download inside the machine instead:
                  cmux vm exec \(vmID) -- git clone <url>
                  cmux vm exec \(vmID) -- curl -LO <url>
                """)
        }

        let localDigest = SHA256.hash(data: payloadData).map { String(format: "%02x", $0) }.joined()
        let remoteStaging: String
        let extractDestination: String?
        if isDirectory.boolValue {
            remoteStaging = "/tmp/cmux-push-\(UUID().uuidString.prefix(8)).tgz"
            extractDestination = remotePath
        } else {
            remoteStaging = remotePath + ".cmux-partial-\(UUID().uuidString.prefix(8))"
            extractDestination = nil
        }

        try uploadData(
            payloadData,
            to: remoteStaging,
            finalDestination: extractDestination == nil ? remotePath : nil,
            vmID: vmID,
            expectedDigest: localDigest,
            client: client
        )

        if let extractDestination {
            let quotedTar = shellQuote(remoteStaging)
            let quotedDest = shellQuote(extractDestination)
            let extract = "mkdir -p \(quotedDest) && tar -xzf \(quotedTar) -C \(quotedDest) && rm -f \(quotedTar)"
            let response = try vmTransferExec(command: extract, vmID: vmID, client: client)
            try requireExecSuccess(response, context: "extracting \(remoteStaging) into \(extractDestination)")
        }

        let seconds = Int(Date().timeIntervalSince(started).rounded())
        if jsonOutput {
            var payload: [String: Any] = [
                "ok": true,
                "direction": "push",
                "vm": vmID,
                "local": localPath,
                "remote": remotePath,
                "kind": isDirectory.boolValue ? "directory" : "file",
                "bytes": payloadData.count,
                "sha256": localDigest,
                "seconds": seconds,
            ]
            if !appliedExcludes.isEmpty {
                payload["excluded"] = appliedExcludes
            }
            print(jsonString(payload))
            return
        }
        let template = CMUXDiffViewerLocalization.string(
            "cli.vm.push.summary",
            defaultValue: "Pushed %1$@ to %2$@:%3$@ (%4$@)"
        )
        let summary = String(format: template, localPath, vmID, remotePath, Self.formatByteCount(payloadData.count))
        var notes: [String] = []
        if !appliedExcludes.isEmpty {
            let excludedTemplate = CMUXDiffViewerLocalization.string(
                "cli.vm.push.excludedNote",
                defaultValue: "Skipped: %1$@ (pass --no-default-excludes to send everything)"
            )
            notes.append(String(format: excludedTemplate, appliedExcludes.joined(separator: ", ")))
        }
        // `vm run` embeds pushes: stdout stays reserved for the command's own
        // output, so the transfer summary goes to stderr instead.
        for line in [summary] + notes {
            if quiet {
                cliWriteStderr(line + "\n")
            } else {
                print(line)
            }
        }
    }

    // MARK: - pull

    func runVMPullCommand(rest: [String], client: SocketClient, jsonOutput: Bool, quiet: Bool = false) throws {
        if rest.contains("--help") || rest.contains("-h") {
            print(Self.vmPullUsage)
            return
        }
        let positional = rest.filter { !$0.hasPrefix("--") }
        guard positional.count == rest.count else {
            let unknown = rest.first { $0.hasPrefix("--") } ?? ""
            throw CLIError(message: "Unknown option \(unknown)\n\n\(Self.vmPullUsage)")
        }
        guard positional.count >= 2, positional.count <= 3 else {
            throw CLIError(message: Self.vmPullUsage)
        }
        let vmID = positional[0]
        let remotePath = positional[1]
        let remoteBasename = (remotePath as NSString).lastPathComponent
        let localPath = (positional.count == 3 ? positional[2] : remoteBasename)
        let localURL = URL(fileURLWithPath: (localPath as NSString).expandingTildeInPath)

        let started = Date()
        let quotedRemote = shellQuote(remotePath)
        let statCommand = "p=\(quotedRemote); if [ -d \"$p\" ]; then echo CMUX_DIR; elif [ -f \"$p\" ]; then echo CMUX_FILE; else echo CMUX_MISSING; fi"
        let statResponse = try vmTransferExec(command: statCommand, vmID: vmID, client: client)
        try requireExecSuccess(statResponse, context: "inspecting \(remotePath)")
        let statOut = ((statResponse["stdout"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        let sourcePath: String
        var remoteTarToCleanUp: String?
        let isDirectory: Bool
        switch statOut {
        case "CMUX_DIR":
            isDirectory = true
            let tarPath = "/tmp/cmux-pull-\(UUID().uuidString.prefix(8)).tgz"
            let packCommand = "tar -czf \(shellQuote(tarPath)) -C \(quotedRemote) ."
            let packResponse = try vmTransferExec(command: packCommand, vmID: vmID, client: client)
            try requireExecSuccess(packResponse, context: "packing \(remotePath)")
            sourcePath = tarPath
            remoteTarToCleanUp = tarPath
        case "CMUX_FILE":
            isDirectory = false
            sourcePath = remotePath
        case "CMUX_MISSING":
            throw CLIError(message: "No such path on \(vmID): \(remotePath)")
        default:
            throw CLIError(message: "Could not inspect \(remotePath) on \(vmID): \(statOut)")
        }
        defer {
            if let remoteTarToCleanUp {
                _ = try? vmTransferExec(command: "rm -f \(shellQuote(remoteTarToCleanUp))", vmID: vmID, client: client)
            }
        }

        let data = try downloadData(from: sourcePath, vmID: vmID, client: client)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()

        if isDirectory {
            let stagingTar = FileManager.default.temporaryDirectory
                .appendingPathComponent("cmux-pull-\(UUID().uuidString.prefix(8)).tgz")
            try data.write(to: stagingTar, options: [.atomic])
            defer { try? FileManager.default.removeItem(at: stagingTar) }
            try FileManager.default.createDirectory(at: localURL, withIntermediateDirectories: true)
            let untar = Process()
            untar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            untar.arguments = ["-xzf", stagingTar.path, "-C", localURL.path]
            try cliRunProcess(untar)
            untar.waitUntilExit()
            guard untar.terminationStatus == 0 else {
                throw CLIError(message: "tar failed extracting into \(localURL.path) (exit \(untar.terminationStatus))")
            }
        } else {
            let parent = localURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            try data.write(to: localURL, options: [.atomic])
        }

        let seconds = Int(Date().timeIntervalSince(started).rounded())
        if jsonOutput {
            let payload: [String: Any] = [
                "ok": true,
                "direction": "pull",
                "vm": vmID,
                "remote": remotePath,
                "local": localURL.path,
                "kind": isDirectory ? "directory" : "file",
                "bytes": data.count,
                "sha256": digest,
                "seconds": seconds,
            ]
            print(jsonString(payload))
            return
        }
        let template = CMUXDiffViewerLocalization.string(
            "cli.vm.pull.summary",
            defaultValue: "Pulled %1$@:%2$@ to %3$@ (%4$@)"
        )
        let summary = String(format: template, vmID, remotePath, localURL.path, Self.formatByteCount(data.count))
        if quiet {
            cliWriteStderr(summary + "\n")
        } else {
            print(summary)
        }
    }

    // MARK: - wait

    func runVMWaitCommand(rest: [String], client: SocketClient, jsonOutput: Bool) throws {
        if rest.contains("--help") || rest.contains("-h") {
            print(Self.vmWaitUsage)
            return
        }
        var vmID: String?
        var timeoutSeconds = 180
        var wake = false
        var index = 0
        while index < rest.count {
            let arg = rest[index]
            switch arg {
            case "--timeout":
                guard index + 1 < rest.count, let parsed = Int(rest[index + 1]), parsed > 0 else {
                    throw CLIError(message: "--timeout requires a positive number of seconds\n\n\(Self.vmWaitUsage)")
                }
                timeoutSeconds = parsed
                index += 2
            case "--wake":
                wake = true
                index += 1
            default:
                guard !arg.hasPrefix("--") else {
                    throw CLIError(message: "Unknown option \(arg)\n\n\(Self.vmWaitUsage)")
                }
                guard vmID == nil else {
                    throw CLIError(message: Self.vmWaitUsage)
                }
                vmID = arg
                index += 1
            }
        }
        guard let vmID else {
            throw CLIError(message: Self.vmWaitUsage)
        }

        let readiness = try waitForVMReady(vmID: vmID, timeoutSeconds: timeoutSeconds, client: client)
        let lastStatus = readiness.status
        let statusPayload = readiness.payload
        let started = Date().addingTimeInterval(-TimeInterval(readiness.waitedSeconds))

        if wake {
            let response = try vmTransferExec(command: "true", vmID: vmID, client: client)
            try requireExecSuccess(response, context: "waking \(vmID)")
        }

        let seconds = Int(Date().timeIntervalSince(started).rounded())
        if jsonOutput {
            var payload = statusPayload
            payload["ok"] = true
            payload["waited_seconds"] = seconds
            payload["woke"] = wake
            print(jsonString(payload))
            return
        }
        let template = CMUXDiffViewerLocalization.string(
            "cli.vm.wait.ready",
            defaultValue: "%1$@ is ready (%2$@) after %3$ds"
        )
        print(String(format: template, vmID, lastStatus, seconds))
    }

    /// Polls `vm.status` until the machine reports a ready status. Ready/pending
    /// sets mirror MachineSnapshotBuilder.activity in the app, so the CLI and the
    /// Machines panel agree on what "ready" means.
    @discardableResult
    func waitForVMReady(
        vmID: String,
        timeoutSeconds: Int,
        client: SocketClient
    ) throws -> (status: String, payload: [String: Any], waitedSeconds: Int) {
        let readyStatuses: Set<String> = ["running", "ready", "standby", "paused"]
        let pendingStatuses: Set<String> = ["creating", "starting", "pending", "resuming", "unknown"]

        let started = Date()
        let deadline = started.addingTimeInterval(TimeInterval(timeoutSeconds))
        while true {
            let response = try client.sendV2(method: "vm.status", params: ["id": vmID], responseTimeout: 60)
            let status = ((response["status"] as? String) ?? "unknown").lowercased()
            if readyStatuses.contains(status) {
                return (status, response, Int(Date().timeIntervalSince(started).rounded()))
            }
            guard pendingStatuses.contains(status) else {
                throw CLIError(message: "\(vmID) reached status \"\(status)\" — it will not become ready. Try `cmux vm status \(vmID)`.")
            }
            guard Date() < deadline else {
                throw CLIError(message: "Timed out after \(timeoutSeconds)s waiting for \(vmID) (last status: \(status)). Re-run with --timeout <seconds> to wait longer.")
            }
            Thread.sleep(forTimeInterval: 3)
        }
    }

    // MARK: - transfer plumbing

    /// Chunk progress: rewrites one line on a TTY, but emits whole lines when
    /// stderr is captured (agents, logs) so the counts do not run together.
    private func vmTransferProgress(_ line: String, final: Bool) {
        if isatty(STDERR_FILENO) != 0 {
            cliWriteStderr("\r" + line + (final ? "\n" : ""))
        } else {
            cliWriteStderr(line + "\n")
        }
    }

    private func vmTransferExec(
        command: String,
        vmID: String,
        client: SocketClient
    ) throws -> [String: Any] {
        try client.sendV2(
            method: "vm.exec",
            params: [
                "id": vmID,
                "command": command,
                "timeout_ms": Self.vmTransferExecTimeoutMs,
            ],
            responseTimeout: Self.vmTransferExecResponseTimeout
        )
    }

    private func requireExecSuccess(_ response: [String: Any], context: String) throws {
        let exitCode = (response["exit_code"] as? Int) ?? -1
        guard exitCode == 0 else {
            let stderr = ((response["stderr"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = stderr.isEmpty ? "" : ": \(stderr)"
            throw CLIError(message: "Command failed while \(context) (exit \(exitCode))\(detail)")
        }
    }

    /// Streams `data` to `stagingPath` on the machine in base64 chunks, then —
    /// when `finalDestination` is set — atomically moves it into place. Verifies
    /// SHA-256 (or size when the machine lacks `sha256sum`) either way.
    private func uploadData(
        _ data: Data,
        to stagingPath: String,
        finalDestination: String?,
        vmID: String,
        expectedDigest: String,
        client: SocketClient
    ) throws {
        let quotedStaging = shellQuote(stagingPath)
        var initCommand = ": > \(quotedStaging)"
        if let finalDestination {
            let parent = (finalDestination as NSString).deletingLastPathComponent
            if !parent.isEmpty {
                initCommand = "mkdir -p \(shellQuote(parent)) && " + initCommand
            }
        }
        let initResponse = try vmTransferExec(command: initCommand, vmID: vmID, client: client)
        try requireExecSuccess(initResponse, context: "preparing \(stagingPath)")

        let totalChunks = max(1, (data.count + Self.vmTransferPushChunkBytes - 1) / Self.vmTransferPushChunkBytes)
        var offset = 0
        var chunkIndex = 0
        while offset < data.count {
            let end = min(offset + Self.vmTransferPushChunkBytes, data.count)
            let chunk = data.subdata(in: offset..<end)
            let encoded = chunk.base64EncodedString()
            let append = "printf %s '\(encoded)' | base64 -d >> \(quotedStaging)"
            let response = try vmTransferExec(command: append, vmID: vmID, client: client)
            try requireExecSuccess(response, context: "writing chunk \(chunkIndex + 1)/\(totalChunks) of \(stagingPath)")
            offset = end
            chunkIndex += 1
            if totalChunks > 1 {
                vmTransferProgress("cmux vm push: \(chunkIndex)/\(totalChunks) chunks", final: chunkIndex == totalChunks)
            }
        }

        let verifyTarget: String
        var finalizeCommand = ""
        if let finalDestination {
            finalizeCommand = "mv \(quotedStaging) \(shellQuote(finalDestination)) && "
            verifyTarget = finalDestination
        } else {
            verifyTarget = stagingPath
        }
        let quotedVerify = shellQuote(verifyTarget)
        finalizeCommand += "if command -v sha256sum >/dev/null 2>&1; then sha256sum \(quotedVerify); else wc -c < \(quotedVerify); fi"
        let finalizeResponse = try vmTransferExec(command: finalizeCommand, vmID: vmID, client: client)
        try requireExecSuccess(finalizeResponse, context: "finalizing \(verifyTarget)")
        let stdout = ((finalizeResponse["stdout"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        try Self.verifyTransferIntegrity(
            report: stdout,
            expectedDigest: expectedDigest,
            expectedBytes: data.count,
            subject: "\(vmID):\(verifyTarget)"
        )
    }

    /// Reads a remote file back in base64 chunks, verifying against a digest
    /// taken on the machine before the transfer starts.
    private func downloadData(from remotePath: String, vmID: String, client: SocketClient) throws -> Data {
        let quoted = shellQuote(remotePath)
        let precheck = "wc -c < \(quoted) && (command -v sha256sum >/dev/null 2>&1 && sha256sum \(quoted) || true)"
        let precheckResponse = try vmTransferExec(command: precheck, vmID: vmID, client: client)
        try requireExecSuccess(precheckResponse, context: "sizing \(remotePath)")
        let precheckLines = ((precheckResponse["stdout"] as? String) ?? "")
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let sizeLine = precheckLines.first, let totalBytes = Int(sizeLine) else {
            throw CLIError(message: "Could not size \(remotePath) on \(vmID)")
        }
        guard totalBytes <= Self.vmTransferMaxBytes else {
            throw CLIError(message: """
                \(vmID):\(remotePath) is \(Self.formatByteCount(totalBytes)); \
                vm pull caps out at \(Self.formatByteCount(Self.vmTransferMaxBytes)). \
                Push the data somewhere directly from the machine instead, e.g.:
                  cmux vm exec \(vmID) -- gh release upload ... \(remotePath)
                """)
        }
        let remoteDigest = precheckLines.count > 1 ? precheckLines[1].split(separator: " ").first.map(String.init) : nil

        var data = Data()
        data.reserveCapacity(totalBytes)
        let totalChunks = max(1, (totalBytes + Self.vmTransferChunkBytes - 1) / Self.vmTransferChunkBytes)
        for chunkIndex in 0..<totalChunks {
            let read = "dd if=\(quoted) bs=\(Self.vmTransferChunkBytes) skip=\(chunkIndex) count=1 2>/dev/null | base64"
            let response = try vmTransferExec(command: read, vmID: vmID, client: client)
            try requireExecSuccess(response, context: "reading chunk \(chunkIndex + 1)/\(totalChunks) of \(remotePath)")
            let encoded = ((response["stdout"] as? String) ?? "")
                .components(separatedBy: .whitespacesAndNewlines)
                .joined()
            guard let decoded = Data(base64Encoded: encoded) else {
                throw CLIError(message: "Corrupt chunk \(chunkIndex + 1)/\(totalChunks) while pulling \(remotePath) from \(vmID)")
            }
            data.append(decoded)
            if totalChunks > 1 {
                vmTransferProgress("cmux vm pull: \(chunkIndex + 1)/\(totalChunks) chunks", final: chunkIndex + 1 == totalChunks)
            }
        }

        guard data.count == totalBytes else {
            throw CLIError(message: "Pulled \(data.count) bytes from \(vmID):\(remotePath) but expected \(totalBytes)")
        }
        if let remoteDigest {
            let localDigest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard localDigest == remoteDigest else {
                throw CLIError(message: "Digest mismatch pulling \(vmID):\(remotePath) — expected \(remoteDigest), got \(localDigest)")
            }
        }
        return data
    }

    // MARK: - vm run (the machine router)

    /// Label that marks a machine as belonging to the router's pool. `vm run`
    /// only reuses and scales machines carrying this label, so it never runs
    /// agent workloads on a machine the user set up by hand.
    static let vmRunPoolLabel = "agent-pool"
    static let vmRunDefaultTimeoutSeconds = 600
    static let vmRunCreateWaitSeconds = 300
    /// An awake pool machine above this CPU load is treated as busy and only
    /// used when the pool cannot grow (plan limit).
    static let vmRunBusyCPUPercent = 60.0

    static var vmRunUsage: String {
        """
        Usage: cmux vm run [--sync] [--pull <remote-path>] [--machine <id>] [--new] [--size <2g|4g|8g|16g|32g>] [--timeout <seconds>] -- <command...>

        Run a command on a cloud machine without naming one: reuses an idle
        machine from the router pool (label "\(vmRunPoolLabel)"), wakes a sleeping
        one, or provisions a fresh machine when the pool is empty or busy —
        then executes the command and passes its exit code through.

        Options:
          --sync                Push the current directory to work/<basename> first
                                and run the command there.
          --pull <remote-path>  After the command, pull that path back into the
                                current directory.
          --machine <id>        Skip routing and use this machine.
          --new                 Force a fresh pool machine.
          --size <s>            Memory preset for a machine this run creates.
          --timeout <seconds>   Command timeout (default \(vmRunDefaultTimeoutSeconds)s, max 15 minutes).

        Examples:
          cmux vm run -- uname -a
          cmux vm run --sync -- bun test
          cmux vm run --sync --pull work/app/dist -- sh -c 'cd work/app && bun run build'
        """
    }

    func runVMRunCommand(rest: [String], client: SocketClient, jsonOutput: Bool) throws {
        if rest.contains("--help") || rest.contains("-h") {
            print(Self.vmRunUsage)
            return
        }
        var flags: [String] = rest
        var commandArgv: [String] = []
        if let separator = rest.firstIndex(of: "--") {
            flags = Array(rest[..<separator])
            commandArgv = Array(rest[(separator + 1)...])
        }
        var sync = false
        var forceNew = false
        var pullPath: String?
        var machineOverride: String?
        var sizeOption: String?
        var timeoutSeconds = Self.vmRunDefaultTimeoutSeconds
        var index = 0
        while index < flags.count {
            let arg = flags[index]
            func takeValue() throws -> String {
                guard index + 1 < flags.count else {
                    throw CLIError(message: "\(arg) requires a value\n\n\(Self.vmRunUsage)")
                }
                index += 1
                return flags[index]
            }
            switch arg {
            case "--sync":
                sync = true
            case "--new":
                forceNew = true
            case "--pull":
                pullPath = try takeValue()
            case "--machine":
                machineOverride = try takeValue()
            case "--size":
                sizeOption = try takeValue()
            case "--timeout":
                let raw = try takeValue()
                guard let parsed = Int(raw), parsed > 0 else {
                    throw CLIError(message: "--timeout requires a positive number of seconds\n\n\(Self.vmRunUsage)")
                }
                timeoutSeconds = parsed
            default:
                throw CLIError(message: "Unknown option \(arg)\n\n\(Self.vmRunUsage)")
            }
            index += 1
        }
        guard !commandArgv.isEmpty else {
            throw CLIError(message: Self.vmRunUsage)
        }
        var memoryMb: Int?
        if let sizeOption {
            guard let parsed = Self.parseCloudVMSize(sizeOption) else {
                throw CLIError(message: "vm run: unknown size '\(sizeOption)'. Sizes: 2g, 4g, 8g, 16g, 32g (or memory in MB).")
            }
            memoryMb = parsed
        }

        let started = Date()
        let selection = try selectVMForRun(
            machineOverride: machineOverride,
            forceNew: forceNew,
            memoryMb: memoryMb,
            client: client
        )
        cliWriteStderr("[cmux vm run] \(selection.id) (\(selection.reason))\n")
        Self.saveVMRunBinding(
            workKey: Self.vmRunWorkKey(forDirectory: FileManager.default.currentDirectoryPath),
            machine: selection.id
        )

        var syncedRemoteDir: String?
        var commandPrefix = ""
        if sync {
            let cwd = FileManager.default.currentDirectoryPath
            let basename = (cwd as NSString).lastPathComponent
            let remoteDir = "work/\(basename)"
            try runVMPushCommand(
                rest: [selection.id, cwd, remoteDir],
                client: client,
                jsonOutput: false,
                quiet: true
            )
            syncedRemoteDir = remoteDir
            commandPrefix = "cd \(shellQuote(remoteDir)) && "
        }

        let command = commandPrefix + commandArgv.map(shellQuote).joined(separator: " ")
        let clampedTimeoutMs = min(timeoutSeconds * 1000, 15 * 60 * 1000)
        let response = try client.sendV2(
            method: "vm.exec",
            params: [
                "id": selection.id,
                "command": command,
                "timeout_ms": clampedTimeoutMs,
            ],
            responseTimeout: TimeInterval(timeoutSeconds + 60)
        )
        let stdout = (response["stdout"] as? String) ?? ""
        let stderr = (response["stderr"] as? String) ?? ""
        let exitCode = (response["exit_code"] as? Int) ?? -1

        var pulledTo: String?
        if let pullPath, exitCode == 0 {
            let localName = (pullPath as NSString).lastPathComponent
            try runVMPullCommand(
                rest: [selection.id, pullPath, localName],
                client: client,
                jsonOutput: false,
                quiet: true
            )
            pulledTo = localName
        }

        let seconds = Int(Date().timeIntervalSince(started).rounded())
        if jsonOutput {
            var payload: [String: Any] = [
                "ok": exitCode == 0,
                "machine": selection.id,
                "created": selection.created,
                "exit_code": exitCode,
                "stdout": stdout,
                "stderr": stderr,
                "seconds": seconds,
            ]
            if let syncedRemoteDir { payload["synced_to"] = syncedRemoteDir }
            if let pulledTo { payload["pulled_to"] = pulledTo }
            print(jsonString(payload))
            if exitCode != 0 {
                throw CLIError(message: "exit \(exitCode)", exitCode: exitCode > 0 ? Int32(exitCode) : 1)
            }
            return
        }
        if !stdout.isEmpty { print(stdout, terminator: stdout.hasSuffix("\n") ? "" : "\n") }
        if !stderr.isEmpty {
            cliWriteStderr(stderr)
            if !stderr.hasSuffix("\n") { cliWriteStderr("\n") }
        }
        if exitCode != 0 {
            throw CLIError(message: "exit \(exitCode)", exitCode: exitCode > 0 ? Int32(exitCode) : 1)
        }
    }

    struct VMRunSelection {
        let id: String
        let created: Bool
        let reason: String
    }

    /// Sticky work→machine bindings, keyed by the caller's directory. Reusing
    /// the machine that last ran this directory's work keeps its warm state —
    /// the synced checkout, installed dependencies, build caches — which is what
    /// makes routing feel invisible. Mirrors the sticky-assignment pattern in
    /// the coderouter credential pool.
    struct VMRunBinding: Codable {
        let machine: String
        let updatedAtUnix: Int
    }

    static let vmRunBindingTTLSeconds = 14 * 24 * 3600

    static func vmRunBindingsStoreURL() -> URL {
        // NSHomeDirectory honors $HOME, so tests (and other redirected runs)
        // get an isolated binding store instead of writing the user's.
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".cmuxterm", isDirectory: true)
            .appendingPathComponent("vm-run-bindings.json", isDirectory: false)
    }

    static func vmRunWorkKey(forDirectory path: String) -> String {
        let canonical = URL(fileURLWithPath: path).standardizedFileURL.path
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static func loadVMRunBindings(from url: URL? = nil) -> [String: VMRunBinding] {
        let storeURL = url ?? vmRunBindingsStoreURL()
        guard let data = try? Data(contentsOf: storeURL),
              let store = try? JSONDecoder().decode([String: VMRunBinding].self, from: data) else {
            return [:]
        }
        let cutoff = Int(Date().timeIntervalSince1970) - vmRunBindingTTLSeconds
        return store.filter { $0.value.updatedAtUnix >= cutoff }
    }

    static func saveVMRunBinding(workKey: String, machine: String, to url: URL? = nil) {
        let storeURL = url ?? vmRunBindingsStoreURL()
        var store = loadVMRunBindings(from: storeURL)
        store[workKey] = VMRunBinding(machine: machine, updatedAtUnix: Int(Date().timeIntervalSince1970))
        guard let data = try? JSONEncoder().encode(store) else { return }
        try? FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: storeURL, options: [.atomic])
    }

    /// Routing policy, in order:
    /// 1. `--machine` bypasses routing entirely.
    /// 2. Awake pool machines under the busy threshold, least-loaded first.
    /// 3. Sleeping pool machines (exec wakes them).
    /// 4. Provision a fresh pool machine (unless the plan is at its cap).
    /// 5. At the plan cap: the least-loaded busy pool machine.
    /// Pool membership is the "\(vmRunPoolLabel)" label; the router never touches
    /// machines the user created and named themselves.
    private func selectVMForRun(
        machineOverride: String?,
        forceNew: Bool,
        memoryMb: Int?,
        client: SocketClient
    ) throws -> VMRunSelection {
        if let machineOverride {
            return VMRunSelection(id: machineOverride, created: false, reason: "pinned with --machine")
        }

        let readyStatuses: Set<String> = ["running", "ready", "standby", "paused"]
        var idleAwake: [(id: String, cpu: Double)] = []
        var asleep: [String] = []
        var busy: [(id: String, cpu: Double)] = []

        if !forceNew {
            let listResponse = try client.sendV2(method: "vm.list", responseTimeout: 60)
            let vms = (listResponse["vms"] as? [[String: Any]]) ?? []
            let pool = vms.filter { vm in
                let label = (vm["displayName"] as? String) ?? ""
                let status = ((vm["status"] as? String) ?? "").lowercased()
                return label == Self.vmRunPoolLabel && readyStatuses.contains(status)
            }
            // Sticky binding beats load: the machine that last ran this
            // directory's work holds its synced checkout and installed deps.
            let workKey = Self.vmRunWorkKey(forDirectory: FileManager.default.currentDirectoryPath)
            if let binding = Self.loadVMRunBindings()[workKey],
               pool.contains(where: { ($0["id"] as? String) == binding.machine }) {
                return VMRunSelection(id: binding.machine, created: false, reason: "reused, warm machine for this directory")
            }
            for vm in pool {
                guard let id = vm["id"] as? String else { continue }
                guard let stats = try? client.sendV2(method: "vm.stats", params: ["id": id], responseTimeout: 60) else {
                    // A machine that cannot report stats is still usable — treat
                    // it like a sleeper rather than dropping it from the pool.
                    asleep.append(id)
                    continue
                }
                let state = ((stats["state"] as? String) ?? "").lowercased()
                if state == "asleep" {
                    asleep.append(id)
                    continue
                }
                let cpu = (stats["cpu_percent"] as? Double) ?? Double(stats["cpu_percent"] as? Int ?? 0)
                if cpu < Self.vmRunBusyCPUPercent {
                    idleAwake.append((id, cpu))
                } else {
                    busy.append((id, cpu))
                }
            }
            if let best = idleAwake.min(by: { $0.cpu < $1.cpu }) {
                return VMRunSelection(id: best.id, created: false, reason: "reused, awake and idle")
            }
            if let sleeper = asleep.first {
                return VMRunSelection(id: sleeper, created: false, reason: "reused, waking from sleep")
            }
        }

        do {
            let id = try createPoolVM(memoryMb: memoryMb, client: client)
            return VMRunSelection(id: id, created: true, reason: "provisioned a fresh pool machine")
        } catch let error as CLIError {
            if error.vmBackendCode == "vm_active_limit_exceeded", let leastBusy = busy.min(by: { $0.cpu < $1.cpu }) {
                return VMRunSelection(id: leastBusy.id, created: false, reason: "plan at machine cap; sharing the least-loaded pool machine")
            }
            throw error
        }
    }

    private func createPoolVM(memoryMb: Int?, client: SocketClient) throws -> String {
        var params: [String: Any] = [
            "image": Self.cloudVMBaseImage,
            "persistent_home": true,
            "per_machine_home": true,
            // Fresh key per run: a failed create is simply retried by the next
            // `vm run`, and the interactive `vm new` store stays untouched.
            "idempotency_key": UUID().uuidString,
        ]
        if let memoryMb { params["memory_mb"] = memoryMb }
        let response = try client.sendV2(
            method: "vm.create",
            params: params,
            responseTimeout: Self.vmCreateResponseTimeoutSeconds
        )
        guard let id = response["id"] as? String, !id.isEmpty else {
            throw CLIError(message: "vm run: create returned no machine id")
        }
        // Label failures are cosmetic (the machine still works this run), but an
        // unlabeled machine would leak out of the pool, so surface the problem.
        do {
            _ = try client.sendV2(
                method: "vm.rename",
                params: ["id": id, "display_name": Self.vmRunPoolLabel],
                responseTimeout: 60
            )
        } catch {
            cliWriteStderr("[cmux vm run] warning: could not label \(id) as \(Self.vmRunPoolLabel); future runs will not reuse it\n")
        }
        try waitForVMReady(vmID: id, timeoutSeconds: Self.vmRunCreateWaitSeconds, client: client)
        return id
    }

    /// `report` is either `"<sha256hex>  <path>"` (sha256sum) or a bare byte
    /// count (wc -c fallback).
    static func verifyTransferIntegrity(
        report: String,
        expectedDigest: String,
        expectedBytes: Int,
        subject: String
    ) throws {
        let firstToken = report.split(separator: " ").first.map(String.init) ?? ""
        if firstToken.count == 64, firstToken.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil {
            guard firstToken == expectedDigest else {
                throw CLIError(message: "Digest mismatch on \(subject) — expected \(expectedDigest), machine reports \(firstToken)")
            }
            return
        }
        if let reportedBytes = Int(firstToken) {
            guard reportedBytes == expectedBytes else {
                throw CLIError(message: "Size mismatch on \(subject) — expected \(expectedBytes) bytes, machine reports \(reportedBytes)")
            }
            return
        }
        throw CLIError(message: "Could not verify \(subject): unexpected report \"\(report)\"")
    }

    private func makeLocalTarball(of directory: URL, excludes: [String]) throws -> URL {
        let tarURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-push-\(UUID().uuidString.prefix(8)).tgz")
        var arguments = ["-czf", tarURL.path, "-C", directory.path]
        for pattern in excludes {
            arguments.append("--exclude")
            arguments.append(pattern)
        }
        arguments.append(".")
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = arguments
        // macOS tar otherwise emits AppleDouble `._*` sidecars for extended
        // attributes, which land as junk files on the Linux machine.
        tar.environment = ProcessInfo.processInfo.environment.merging(["COPYFILE_DISABLE": "1"]) { _, new in new }
        try cliRunProcess(tar)
        tar.waitUntilExit()
        guard tar.terminationStatus == 0 else {
            throw CLIError(message: "tar failed packing \(directory.path) (exit \(tar.terminationStatus))")
        }
        return tarURL
    }

    static func formatByteCount(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}
