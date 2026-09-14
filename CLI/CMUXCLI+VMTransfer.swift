import CmuxSettings
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
    static let vmPushWatchSettleTimeoutSeconds: TimeInterval = 10
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
               cmux vm push <id> <local-path> [remote-path] --watch [--interval <seconds>] [--exclude <pattern>]...
               cmux vm push --secret <id> <local-file> [remote-path] [--mode <octal>]

        Copy a local file or directory onto a cloud machine over the exec channel
        (no SSH needed). Directories travel as tarballs; by default \(vmPushDefaultExcludes.joined(separator: ", "))
        are skipped. The remote path defaults to the local basename in the exec
        working directory (the machine user's home).

        --watch keeps syncing: after the first push it pushes again whenever a file
        under <local-path> changes (polled every --interval seconds, default 1;
        the same excludes apply), printing one line per sync, until Ctrl-C.

        --secret is for a file that must never transit the control plane (a token
        file, a deploy key, an .npmrc). It travels over the machine's cmux-tui link
        into the in-VM `cmux file receive`, which turns terminal echo off before it
        reads, writes the file with --mode (default 600), and moves it into place
        atomically — the same path `cmux vm env set` uses. One file up to 256 KiB;
        not combinable with --watch or --exclude.

        Examples:
          cmux vm push brave-otter ./script.sh
          cmux vm push brave-otter ./myrepo work/myrepo
          cmux vm push brave-otter ./site --exclude dist
          cmux vm push brave-otter . work/app --watch
          cmux vm push --secret brave-otter ~/.npmrc .npmrc
          cmux vm push --secret brave-otter ./deploy_key .ssh/deploy_key --mode 600
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

    /// `DisableFileTransfer` (MDM). The CLI performs the transfer itself, so
    /// it resolves the forced preference directly rather than trusting a flag
    /// from its own process. Same resolver, same release-domain fallback the
    /// app uses.
    static func throwIfFileTransferIsManagedOff() throws {
        guard ManagedDevicePolicy().isEnforced(.disableFileTransfer) else { return }
        throw CLIError(message: String(
            localized: "managedPolicy.fileTransfer.disabled",
            defaultValue: "File transfer is disabled by your organization."
        ))
    }

    func runVMPushCommand(rest: [String], client: SocketClient, jsonOutput: Bool, quiet: Bool = false) throws {
        if rest.contains("--help") || rest.contains("-h") {
            print(Self.vmPushUsage)
            return
        }
        // Help stays readable under the policy; only the transfer is refused.
        try Self.throwIfFileTransferIsManagedOff()
        var positional: [String] = []
        var extraExcludes: [String] = []
        var useDefaultExcludes = true
        var secret = false
        var modeOption: String?
        var watch = false
        var intervalOption: String?
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
            case "--secret":
                secret = true
                index += 1
            case "--mode":
                guard index + 1 < rest.count else {
                    throw CLIError(message: "--mode requires an octal file mode such as 600\n\n\(Self.vmPushUsage)")
                }
                modeOption = rest[index + 1]
                index += 2
            case "--watch":
                watch = true
                index += 1
            case "--interval":
                guard index + 1 < rest.count else {
                    throw CLIError(message: "--interval requires a number of seconds\n\n\(Self.vmPushUsage)")
                }
                intervalOption = rest[index + 1]
                index += 2
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
        let remotePath = positional.count == 3 ? positional[2] : localURL.lastPathComponent

        if secret {
            guard !watch, extraExcludes.isEmpty, useDefaultExcludes else {
                throw CLIError(message: "vm push --secret delivers one file once; it does not combine with --watch, --exclude, or --no-default-excludes\n\n\(Self.vmPushUsage)")
            }
            try pushSecretFile(
                vmID: vmID,
                localURL: localURL,
                localPath: localPath,
                isDirectory: isDirectory.boolValue,
                remotePath: remotePath,
                mode: modeOption ?? Self.vmSecretPushDefaultMode,
                client: client,
                jsonOutput: jsonOutput
            )
            return
        }
        guard modeOption == nil else {
            throw CLIError(message: "--mode belongs to --secret (exec-channel pushes keep the tarball's own modes)\n\n\(Self.vmPushUsage)")
        }
        var intervalSeconds = Self.vmPushWatchDefaultIntervalSeconds
        if let intervalOption {
            guard watch else {
                throw CLIError(message: "--interval belongs to --watch\n\n\(Self.vmPushUsage)")
            }
            guard let parsed = Double(intervalOption), parsed >= 0.2, parsed <= 60 else {
                throw CLIError(message: "--interval must be between 0.2 and 60 seconds (got '\(intervalOption)')\n\n\(Self.vmPushUsage)")
            }
            intervalSeconds = parsed
        }
        let excludes = isDirectory.boolValue ? (useDefaultExcludes ? Self.vmPushDefaultExcludes : []) + extraExcludes : []
        let initialWatchSignature = watch
            ? Self.vmPushTreeSignature(root: localURL, isDirectory: isDirectory.boolValue, excludes: excludes)
            : nil

        let outcome = try performVMPush(
            vmID: vmID,
            localURL: localURL,
            localPath: localPath,
            isDirectory: isDirectory.boolValue,
            remotePath: remotePath,
            excludes: excludes,
            client: client
        )
        if jsonOutput && !watch {
            print(jsonString(outcome.jsonPayload))
            return
        }
        if jsonOutput {
            var payload = outcome.jsonPayload
            payload["event"] = "synced"
            payload["files"] = Self.vmPushTreeSignature(
                root: localURL,
                isDirectory: isDirectory.boolValue,
                excludes: excludes
            ).count
            payload["sync"] = 0
            print(jsonString(payload, prettyPrinted: false))
            fflush(stdout)
        }
        // `vm run` embeds pushes: stdout stays reserved for the command's own
        // output, so the transfer summary goes to stderr instead.
        for line in outcome.summaryLines() {
            if jsonOutput {
                continue
            } else if quiet {
                cliWriteStderr(line + "\n")
            } else {
                print(line)
            }
        }
        guard watch else { return }
        try watchAndPush(
            vmID: vmID,
            localURL: localURL,
            localPath: localPath,
            isDirectory: isDirectory.boolValue,
            remotePath: remotePath,
            excludes: excludes,
            intervalSeconds: intervalSeconds,
            client: client,
            jsonOutput: jsonOutput,
            initialSignature: initialWatchSignature
        )
    }

    /// What one exec-channel push did, for the human summary or the JSON payload.
    struct VMPushOutcome {
        let vmID: String
        let localPath: String
        let remotePath: String
        let isDirectory: Bool
        let bytes: Int
        let sha256: String
        let seconds: Int
        let appliedExcludes: [String]

        var jsonPayload: [String: Any] {
            var payload: [String: Any] = [
                "ok": true,
                "direction": "push",
                "vm": vmID,
                "local": localPath,
                "remote": remotePath,
                "kind": isDirectory ? "directory" : "file",
                "bytes": bytes,
                "sha256": sha256,
                "seconds": seconds,
            ]
            if !appliedExcludes.isEmpty {
                payload["excluded"] = appliedExcludes
            }
            return payload
        }

        func summaryLines() -> [String] {
            let template = CMUXDiffViewerLocalization.string(
                "cli.vm.push.summary",
                defaultValue: "Pushed %1$@ to %2$@:%3$@ (%4$@)"
            )
            var lines = [String(format: template, localPath, vmID, remotePath, CMUXCLI.formatByteCount(bytes))]
            if !appliedExcludes.isEmpty {
                let excludedTemplate = CMUXDiffViewerLocalization.string(
                    "cli.vm.push.excludedNote",
                    defaultValue: "Skipped: %1$@ (pass --no-default-excludes to send everything)"
                )
                lines.append(String(format: excludedTemplate, appliedExcludes.joined(separator: ", ")))
            }
            return lines
        }
    }

    /// One push over the exec channel: pack (directories), upload in base64 chunks,
    /// verify the digest, extract. Shared by the one-shot command, `--watch`, and the
    /// `vm run` / `vm agent` `--sync` paths.
    func performVMPush(
        vmID: String,
        localURL: URL,
        localPath: String,
        isDirectory: Bool,
        remotePath: String,
        excludes: [String],
        client: SocketClient
    ) throws -> VMPushOutcome {
        let started = Date()
        let payloadData: Data
        var stagingTarURL: URL?
        if isDirectory {
            let tarURL = try makeLocalTarball(of: localURL, excludes: excludes)
            stagingTarURL = tarURL
            do {
                payloadData = try Data(contentsOf: tarURL)
            } catch {
                // The deferred cleanup below is not installed yet; do not leak a
                // large staging tarball in the temp directory on a read failure.
                try? FileManager.default.removeItem(at: tarURL)
                throw error
            }
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
        if isDirectory {
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

        return VMPushOutcome(
            vmID: vmID,
            localPath: localPath,
            remotePath: remotePath,
            isDirectory: isDirectory,
            bytes: payloadData.count,
            sha256: localDigest,
            seconds: Int(Date().timeIntervalSince(started).rounded()),
            appliedExcludes: excludes
        )
    }

    // MARK: - push --secret (over the link, never the exec channel)

    /// Same ceiling as `cmux vm env set`: the receiver reads a PTY, a control channel.
    static let vmSecretPushMaxBytes = 256 * 1024
    static let vmSecretPushDefaultMode = "600"

    /// One file over the machine's link into `cmux file receive` (socket `vm.file_put`),
    /// so the bytes never appear in a command line, on the control plane, or on a
    /// terminal's screen. The app runs the receiver protocol (`CloudFileDelivery`);
    /// the CLI only reads the file and reports what landed.
    private func pushSecretFile(
        vmID: String,
        localURL: URL,
        localPath: String,
        isDirectory: Bool,
        remotePath: String,
        mode: String,
        client: SocketClient,
        jsonOutput: Bool
    ) throws {
        guard !isDirectory else {
            throw CLIError(message: "vm push --secret delivers one file; \(localPath) is a directory. Pack it first (tar czf), or push it without --secret if it holds nothing secret.")
        }
        guard mode.range(of: "^[0-7]{3,4}$", options: .regularExpression) != nil else {
            throw CLIError(message: "--mode must be three or four octal digits such as 600 or 0644 (got '\(mode)')")
        }
        let data = try Data(contentsOf: localURL)
        guard !data.isEmpty else {
            throw CLIError(message: "\(localPath) is empty; nothing to deliver")
        }
        guard data.count <= Self.vmSecretPushMaxBytes else {
            throw CLIError(message: """
                \(localPath) is \(Self.formatByteCount(data.count)); --secret delivers up to \
                \(Self.formatByteCount(Self.vmSecretPushMaxBytes)) over the link. Larger files that hold \
                nothing secret go through `cmux vm push` without --secret.
                """)
        }
        let started = Date()
        let response = try client.sendV2(
            method: "vm.file_put",
            params: [
                "id": vmID,
                "path": remotePath,
                "mode": mode,
                "data_base64": data.base64EncodedString(),
            ],
            responseTimeout: 260
        )
        let bytes = (response["bytes"] as? Int) ?? data.count
        let landedPath = (response["path"] as? String) ?? remotePath
        let landedMode = (response["mode"] as? String) ?? mode
        if jsonOutput {
            print(jsonString([
                "ok": true,
                "direction": "push",
                "vm": vmID,
                "local": localPath,
                "remote": landedPath,
                "kind": "file",
                "bytes": bytes,
                "mode": landedMode,
                "transport": "link",
                "seconds": Int(Date().timeIntervalSince(started).rounded()),
            ]))
            return
        }
        print(String(
            format: String(localized: "cli.vm.push.secretDelivered", defaultValue: "OK %1$@ (%2$ld bytes, mode %3$@) delivered over the link"),
            landedPath, bytes, landedMode
        ))
    }

    // MARK: - push --watch

    static let vmPushWatchDefaultIntervalSeconds = 1.0
    /// A tree in the middle of a save (an editor writing several files, a `git checkout`)
    /// must settle before it is packed, or the machine gets a half-written state.
    static let vmPushWatchSettleSeconds = 0.3

    /// What `--watch` compares between polls: every regular file under the root that the
    /// excludes let through, with the two cheap facts that change when a file does.
    struct VMPushTreeEntry: Equatable {
        let modified: TimeInterval
        let size: Int
        let permissions: Int
    }

    /// True when tar's `--exclude <pattern>` would skip a path with this component: the
    /// literal name or a shell glob (`*.log`) matched against each path component.
    static func vmPushIsExcluded(_ relativePath: String, excludes: [String]) -> Bool {
        guard !excludes.isEmpty else { return false }
        for component in relativePath.split(separator: "/") {
            let name = String(component)
            for pattern in excludes where name == pattern || fnmatch(pattern, name, 0) == 0 {
                return true
            }
        }
        return false
    }

    /// A single file's signature is itself; a directory's is every file beneath it.
    static func vmPushTreeSignature(root: URL, isDirectory: Bool, excludes: [String]) -> [String: VMPushTreeEntry] {
        func entry(_ url: URL) -> VMPushTreeEntry? {
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else { return nil }
            return VMPushTreeEntry(
                modified: values.contentModificationDate?.timeIntervalSince1970 ?? 0,
                size: values.fileSize ?? 0,
                permissions: ((try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]) as? NSNumber)?.intValue ?? 0
            )
        }
        guard isDirectory else {
            return entry(root).map { [root.lastPathComponent: $0] } ?? [:]
        }
        var signature: [String: VMPushTreeEntry] = [:]
        let rootPath = root.standardizedFileURL.path
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey, .isDirectoryKey],
            options: []
        ) else { return signature }
        while let next = enumerator.nextObject() as? URL {
            let fullPath = next.standardizedFileURL.path
            var relative = fullPath.hasPrefix(rootPath) ? String(fullPath.dropFirst(rootPath.count)) : next.lastPathComponent
            if relative.hasPrefix("/") { relative.removeFirst() }
            if Self.vmPushIsExcluded(relative, excludes: excludes) {
                if (try? next.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    enumerator.skipDescendants()
                }
                continue
            }
            if let fileEntry = entry(next) {
                signature[relative] = fileEntry
            }
        }
        return signature
    }

    /// Polls the local tree and pushes again whenever it changes, until Ctrl-C (exit 0).
    /// `CMUX_VM_PUSH_WATCH_ROUNDS=<n>` (tests) ends the watch after n syncs.
    private func watchAndPush(
        vmID: String,
        localURL: URL,
        localPath: String,
        isDirectory: Bool,
        remotePath: String,
        excludes: [String],
        intervalSeconds: Double,
        client: SocketClient,
        jsonOutput: Bool,
        initialSignature: [String: VMPushTreeEntry]?
    ) throws {
        // Ctrl-C ends the watch, not the CLI's shell: exit 0 straight from the handler
        // (`_exit` is async-signal-safe; nothing here needs unwinding).
        signal(SIGINT) { _ in _exit(0) }
        let maxRounds = ProcessInfo.processInfo.environment["CMUX_VM_PUSH_WATCH_ROUNDS"].flatMap { Int($0) }
        var last = initialSignature ?? Self.vmPushTreeSignature(root: localURL, isDirectory: isDirectory, excludes: excludes)
        if !jsonOutput {
            cliWriteStderr("watching \(localPath) (\(last.count) files) — every change is pushed to \(vmID):\(remotePath); Ctrl-C stops\n")
        }
        var syncs = 0
        let clock = DateFormatter()
        clock.dateFormat = "HH:mm:ss"
        while true {
            Thread.sleep(forTimeInterval: intervalSeconds)
            var current = Self.vmPushTreeSignature(root: localURL, isDirectory: isDirectory, excludes: excludes)
            guard current != last else { continue }
            // Settle: keep re-reading until two consecutive reads agree.
            let settleDeadline = Date().addingTimeInterval(Self.vmPushWatchSettleTimeoutSeconds)
            while Date() < settleDeadline {
                Thread.sleep(forTimeInterval: Self.vmPushWatchSettleSeconds)
                let settled = Self.vmPushTreeSignature(root: localURL, isDirectory: isDirectory, excludes: excludes)
                if settled == current { break }
                current = settled
            }
            // A transient edit may disappear while settling.
            guard current != last else { continue }
            let outcome = try performVMPush(
                vmID: vmID,
                localURL: localURL,
                localPath: localPath,
                isDirectory: isDirectory,
                remotePath: remotePath,
                excludes: excludes,
                client: client
            )
            last = current
            syncs += 1
            if jsonOutput {
                var payload = outcome.jsonPayload
                payload["event"] = "synced"
                payload["files"] = current.count
                payload["sync"] = syncs
                print(jsonString(payload, prettyPrinted: false))
            } else {
                print("synced \(current.count) files at \(clock.string(from: Date())) (\(Self.formatByteCount(outcome.bytes)))")
            }
            fflush(stdout)
            if let maxRounds, syncs >= maxRounds { return }
        }
    }

    // MARK: - pull

    func runVMPullCommand(rest: [String], client: SocketClient, jsonOutput: Bool, quiet: Bool = false) throws {
        if rest.contains("--help") || rest.contains("-h") {
            print(Self.vmPullUsage)
            return
        }
        // Help stays readable under the policy; only the transfer is refused.
        try Self.throwIfFileTransferIsManagedOff()
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
    /// Returns whether the TTY line still needs a newline if the transfer fails.
    private func vmTransferProgress(_ line: String, final: Bool) -> Bool {
        if isatty(STDERR_FILENO) != 0 {
            cliWriteStderr("\r" + line + (final ? "\n" : ""))
            return !final
        } else {
            cliWriteStderr(line + "\n")
            return false
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
        var progressLineOpen = false
        defer {
            if progressLineOpen { cliWriteStderr("\n") }
        }
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
                let template = CMUXDiffViewerLocalization.string(
                    "cli.vm.push.progress",
                    defaultValue: "cmux vm push: %1$d/%2$d chunks"
                )
                progressLineOpen = vmTransferProgress(String(format: template, chunkIndex, totalChunks), final: chunkIndex == totalChunks)
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
        var progressLineOpen = false
        defer {
            if progressLineOpen { cliWriteStderr("\n") }
        }
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
                let template = CMUXDiffViewerLocalization.string(
                    "cli.vm.pull.progress",
                    defaultValue: "cmux vm pull: %1$d/%2$d chunks"
                )
                progressLineOpen = vmTransferProgress(String(format: template, chunkIndex + 1, totalChunks), final: chunkIndex + 1 == totalChunks)
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

    /// Display label the router puts on machines it provisions so the pool is
    /// recognizable in `vm ls` and the Machines panel. It is *not* the membership
    /// test — display names are user-editable, so a hand-made machine renamed
    /// "agent-pool" must never be drafted. Membership is the persisted id list in
    /// `~/.cmuxterm/vm-run-pool.json`, written only by `createPoolVM`.
    static let vmRunPoolLabel = "agent-pool"
    static let vmRunDefaultTimeoutSeconds = 600
    static let vmRunCreateWaitSeconds = 300
    /// An awake pool machine above this CPU load is treated as busy and only
    /// used when the pool cannot grow (plan limit).
    static let vmRunBusyCPUPercent = 60.0

    static var vmRunUsage: String {
        """
        Usage: cmux vm run [--sync] [--pull <remote-path>] [--machine <id>] [--new] [--size <20g>] [--timeout <seconds>] -- <command...>

        Run a command on a cloud machine without naming one: reuses an idle
        machine the router itself provisioned earlier (shown as "\(vmRunPoolLabel)"
        in `cmux vm ls`), wakes a sleeping one, or provisions a fresh machine
        when the pool is empty or busy — then executes the command and passes
        its exit code through. Machines you created by hand are never drafted;
        use --machine <id> to run on one deliberately.

        Options:
          --sync                Push the current directory to work/<basename> first
                                and run the command there.
          --pull <remote-path>  After the command, pull that path back into the
                                current directory.
          --machine <id>        Skip routing and use this machine.
          --new                 Force a fresh pool machine.
          --size <s>            Memory preset for a machine this run creates.
          --timeout <seconds>   Command timeout (default \(vmRunDefaultTimeoutSeconds)s, max 15 minutes).
          --wait, --output      Accepted for symmetry with `vm agent`; `vm run` always
                                blocks on the command and prints its output.

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
            case "--wait", "--output":
                // Implied: `vm run` always blocks on the command and prints its output.
                // Accepted so a script can pass the flags it passes to `vm agent`.
                break
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
                throw CLIError(message: "vm run: unknown size '\(sizeOption)'. Sizes: 20g (the plan machine) or memory in MB (at least 512).")
            }
            memoryMb = parsed
        }

        if sync || pullPath != nil {
            try Self.throwIfFileTransferIsManagedOff()
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
        /// `vm route` without `--provision`: the router stopped short of creating a machine.
        var wouldProvision: Bool = false
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

    /// The home the router keeps its state under. `$HOME` first: NSHomeDirectory()
    /// resolves through Core Foundation (CFFIXED_USER_HOME, then the passwd entry)
    /// and ignores a HOME override, so tests and other redirected runs would write
    /// the user's real `~/.cmuxterm` instead of their own.
    static func vmRunStateHomeDirectory() -> String {
        if let home = ProcessInfo.processInfo.environment["HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !home.isEmpty {
            return home
        }
        return NSHomeDirectory()
    }

    static func vmRunBindingsStoreURL() -> URL {
        URL(fileURLWithPath: vmRunStateHomeDirectory(), isDirectory: true)
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

    /// Machines this router provisioned, persisted per Mac. This list — never the
    /// display label — is what makes a machine eligible for `vm run`.
    struct VMRunPoolStore: Codable {
        var machines: [String]
    }

    static func vmRunPoolStoreURL() -> URL {
        URL(fileURLWithPath: vmRunStateHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".cmuxterm", isDirectory: true)
            .appendingPathComponent("vm-run-pool.json", isDirectory: false)
    }

    static func loadVMRunPool(from url: URL? = nil) -> Set<String> {
        let storeURL = url ?? vmRunPoolStoreURL()
        guard let data = try? Data(contentsOf: storeURL),
              let store = try? JSONDecoder().decode(VMRunPoolStore.self, from: data) else {
            return []
        }
        return Set(store.machines)
    }

    static func saveVMRunPool(_ machines: Set<String>, to url: URL? = nil) throws {
        let storeURL = url ?? vmRunPoolStoreURL()
        let data = try JSONEncoder().encode(VMRunPoolStore(machines: machines.sorted()))
        try FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: storeURL, options: [.atomic])
    }

    /// Read-modify-write on the pool store under an exclusive advisory lock, so
    /// two `vm run` processes provisioning at once cannot each write a set that
    /// only contains its own machine (atomic replacement alone loses the other
    /// id). The lock file sits beside the store; `flock` releases it on close
    /// even if the process dies mid-update.
    /// Fails loudly instead of degrading to an unlocked or unpersisted update: a
    /// machine the router provisioned but could not record would be orphaned from
    /// the pool, so the caller must know.
    static func updateVMRunPool(at url: URL? = nil, _ mutate: (inout Set<String>) -> Void) throws {
        let storeURL = url ?? vmRunPoolStoreURL()
        try FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let lockPath = storeURL.path + ".lock"
        let lockFD = open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard lockFD >= 0 else {
            throw CLIError(message: "vm run: could not open the pool lock at \(lockPath): \(String(cString: strerror(errno)))")
        }
        defer { close(lockFD) }
        guard flock(lockFD, LOCK_EX) == 0 else {
            throw CLIError(message: "vm run: could not lock the pool store at \(lockPath): \(String(cString: strerror(errno)))")
        }
        defer { _ = flock(lockFD, LOCK_UN) }
        var machines = loadVMRunPool(from: storeURL)
        mutate(&machines)
        try saveVMRunPool(machines, to: storeURL)
    }

    /// Routing policy, in order:
    /// 1. `--machine` bypasses routing entirely.
    /// 2. Awake pool machines under the busy threshold, least-loaded first.
    /// 3. Sleeping pool machines (exec wakes them).
    /// 4. Provision a fresh pool machine (unless the plan is at its cap).
    /// 5. At the plan cap: the least-loaded busy pool machine.
    /// Pool membership is the persisted id list from `createPoolVM`; the router
    /// never touches machines the user created themselves, whatever their label.
    /// Internal (not private) so `vm route` can print the decision and `vm agent` can reuse
    /// it; there is exactly one routing policy. `allowProvision: false` stops before creating a
    /// machine and reports `wouldProvision` instead.
    func selectVMForRun(
        machineOverride: String?,
        forceNew: Bool,
        memoryMb: Int?,
        workDirectory: String = FileManager.default.currentDirectoryPath,
        allowProvision: Bool = true,
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
            // Read the pool before listing: every id in this snapshot was recorded
            // before `vm.list` answered, so one that the list does not carry is
            // genuinely gone. An id another `vm run` records after this point is
            // never in `poolIDs`, so the prune below cannot touch it.
            let poolIDs = Self.loadVMRunPool()
            let listResponse = try client.sendV2(method: "vm.list", responseTimeout: 60)
            let vms = (listResponse["vms"] as? [[String: Any]]) ?? []
            // Forget pool ids whose machines are gone (deleted by the user), so the
            // store cannot grow stale or accidentally match a recycled id later.
            let liveIDs = Set(vms.compactMap { $0["id"] as? String })
            let staleIDs = poolIDs.subtracting(liveIDs)
            if !staleIDs.isEmpty {
                // Subtract only the ids this snapshot saw as gone. Intersecting the
                // locked set with `liveIDs` would also drop a machine another `vm run`
                // recorded after the list was taken but before this lock was held.
                try Self.updateVMRunPool { machines in machines.subtract(staleIDs) }
            }
            // Re-read after the prune so a machine another `vm run` recorded between
            // the first load and `vm.list` (and that the list carries) is eligible now
            // instead of pushing this run toward a needless provision.
            let prunedPoolIDs = Self.loadVMRunPool().intersection(liveIDs)
            let pool = vms.filter { vm in
                guard let id = vm["id"] as? String else { return false }
                let status = ((vm["status"] as? String) ?? "").lowercased()
                return prunedPoolIDs.contains(id) && readyStatuses.contains(status)
            }
            // Sticky binding beats load: the machine that last ran this
            // directory's work holds its synced checkout and installed deps.
            let workKey = Self.vmRunWorkKey(forDirectory: workDirectory)
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

        guard allowProvision else {
            return VMRunSelection(id: "", created: false, reason: "would provision a fresh pool machine", wouldProvision: true)
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
            // Pool machines are shell boxes; the backend maps the kind to its image.
            "kind": VMMachineKind.base.rawValue,
            // Freestyle has no persistent-volume capability; keep pool creation usable.
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
        // Membership is recorded before anything else can fail: this is what
        // makes the machine eligible for reuse by later runs.
        // A create that cannot be recorded is surfaced, not hidden: the machine exists
        // on the provider, so the error names it for `--machine` / `vm rm`.
        do {
            try Self.updateVMRunPool { machines in machines.insert(id) }
        } catch {
            // Product-level copy only: the underlying failure names a local lock path
            // and raw OS text, which do not belong in user-facing output.
            let template = CMUXDiffViewerLocalization.string(
                "cli.vm.run.poolRecordFailed",
                defaultValue: "vm run: provisioned %1$@ but could not record it in the pool store, so later runs will not reuse it. Use `cmux vm run --machine %1$@` to keep using it or `cmux vm rm %1$@` to remove it."
            )
            throw CLIError(message: String(format: template, id))
        }
        // The label is cosmetic (membership is already recorded), but without it
        // the machine is not recognizable as pool in `vm ls`, so say so.
        do {
            _ = try client.sendV2(
                method: "vm.rename",
                params: ["id": id, "display_name": Self.vmRunPoolLabel],
                responseTimeout: 60
            )
        } catch {
            cliWriteStderr("[cmux vm run] warning: could not label \(id) as \(Self.vmRunPoolLabel); it stays in the pool but will not show that label in `cmux vm ls`\n")
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


// MARK: - vm route / vm agent (route work, not just commands)

extension CMUXCLI {
    static var vmRouteUsage: String {
        """
        Usage: cmux vm route [--cwd <dir>] [--new] [--provision] [--size <20g>] [--json]

        Print the machine `cmux vm run` / `cmux vm agent` would use for work in a
        directory, and why — without running anything. The policy is the router's
        own: the machine already bound to the directory (warm checkout, installed
        deps), else an awake idle pool machine, else a sleeping one. When the pool
        is empty or busy the router would provision a fresh machine; `vm route`
        says so and stops unless --provision is passed.

        Options:
          --cwd <dir>    Route for this directory (default: the current one).
          --new          Ignore the pool and report a fresh machine.
          --provision    Actually create the machine when routing would.
          --size <s>     Memory preset for a machine --provision creates.
          --json         {machine, created, reason, would_provision, directory}
        """
    }

    static let vmAgentNames = ["claude", "codex", "opencode", "pi"]

    static var vmAgentUsage: String {
        """
        Usage: cmux vm agent --agent <claude|codex|opencode|pi> [--machine <id>] [--sync] [--cwd <dir>] [--name <name>] [--no-open] [--remote-workspace <ws>] [--wait [--output] [--timeout <seconds>]] [--new] [--size <s>] [--json] -- <prompt or args...>

        Short forms:
          cmux agent <claude|codex|opencode|pi> [vm-agent-options] -- <prompt or args...>
          cmux coderouter agent <claude|codex|opencode|pi> [vm-agent-options] -- <prompt or args...>

        Run a coding agent on a cloud machine. The machine is chosen like `vm run`
        (sticky per directory, then idle pool machine, then a fresh one) unless
        --machine pins one. The agent starts as a detached terminal in the
        machine's cmux-tui session, so it keeps running when you close the pane
        and can be reattached from any device with `cmux vm open <machine>/<ws>/<term>`.

        A bare prompt runs the agent's one-shot form (claude -p, codex exec,
        opencode run, pi -p). Arguments that start with a flag or a subcommand
        pass through verbatim.

        Options:
          --agent <name>   claude | codex | opencode | pi (preinstalled on every machine).
          --machine <id>   Skip routing and use this machine.
          --sync           Push --cwd (default: the current directory) to work/<basename>
                           first and start the agent there.
          --cwd <dir>      Local directory to route for (and sync with --sync).
          --name <name>    Terminal name in the tree (default: "<agent>: <prompt…>").
          --no-open        Do not open a pane in this app; just start it.
          --remote-workspace <ws>
                           Land the agent's terminal in this machine workspace
                           (a `ws_…` id from `vm tree`, e.g. one staged with
                           `vm workspace new --no-open`) instead of the detached pool.
          --wait           Block until the agent's process exits and pass its exit
                           code through (`exited code=<n>`; 1 for a signal). Ctrl-C
                           stops waiting only — the agent keeps running detached.
          --output         With --wait: print the agent's whole terminal output on
                           stdout when it ends (the launch lines move to stderr).
          --timeout <s>    With --wait: give up waiting after this many seconds
                           (exit 1, the agent is not stopped). Default: no limit.
          --new            Force a fresh pool machine.
          --size <s>       Memory preset for a machine this call creates.

        Examples:
          cmux vm agent --agent claude --sync -- "run the test suite and fix failures"
          cmux vm agent --agent codex --machine vivid-newt -- exec "summarize work/app"
          cmux vm agent --agent opencode --no-open --json -- "add a README"
          cmux vm agent --agent claude --machine vivid-newt --no-open --wait --output -- "fix the failing test"
        """
    }

    /// Non-interactive argv for an agent given the words after `--`. A bare prompt gets the
    /// agent's one-shot form; anything that starts with a flag or a known subcommand passes
    /// through verbatim so `-- exec …` / `-- --resume …` keep meaning what they say.
    static func vmAgentArgv(agent: String, args: [String]) -> [String]? {
        guard vmAgentNames.contains(agent), let first = args.first else { return nil }
        let passthroughSubcommands: [String: Set<String>] = [
            "claude": ["mcp", "config", "doctor", "update", "install", "auth", "setup-token", "plugin", "agents"],
            "codex": ["exec", "e", "login", "logout", "mcp", "apply", "resume", "completion", "debug", "sandbox", "cloud", "app-server", "features"],
            "opencode": ["run", "auth", "serve", "web", "models", "upgrade", "agent", "session", "export", "import", "github", "mcp", "acp"],
            "pi": ["config", "install", "uninstall", "update", "list", "login", "logout", "mcp"],
        ]
        if first.hasPrefix("-") || (passthroughSubcommands[agent] ?? []).contains(first) {
            return [agent] + args
        }
        let prompt = args.joined(separator: " ")
        switch agent {
        case "claude": return ["claude", "-p", prompt]
        case "codex": return ["codex", "exec", prompt]
        case "opencode": return ["opencode", "run", prompt]
        case "pi": return ["pi", "-p", prompt]
        default: return nil
        }
    }

    /// Normalizes the ergonomic provider-first aliases into the canonical
    /// `vm agent --agent <name> ...` argument shape. VM options are recognized
    /// until the first unrecognized token; the remainder is kept behind `--`
    /// so provider flags and subcommands cannot be mistaken for cmux options.
    static func vmAgentAliasArgs(_ rest: [String]) -> [String] {
        CmuxTuiRemoteRouting.vmAgentAliasArgs(rest)
    }

    /// The default terminal name for an agent run: the agent plus the start of its prompt.
    static func vmAgentTerminalName(agent: String, args: [String]) -> String {
        let prompt = args.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return agent }
        let clipped = prompt.count > 40 ? String(prompt.prefix(40)).trimmingCharacters(in: .whitespaces) + "…" : prompt
        return "\(agent): \(clipped)"
    }

    /// What the machine's cmux-tui session runs: a login shell so the persistent-home tool
    /// paths ($HOME/.npm-global, bun, uv) resolve even before .bashrc is sourced, then exec.
    ///
    /// Every path is relative to the session's own $HOME, never a literal /root: a cmux Cloud
    /// machine runs its sessions as the non-root work user, and older machines run them as
    /// root, so the home is whatever the daemon's user has. `workDirectory` is likewise the
    /// pushed directory relative to that home; if it is gone, the agent starts in the home
    /// rather than failing to launch.
    func vmAgentShellCommand(argv: [String], workDirectory: String? = nil) -> [String] {
        let joined = argv.map(shellQuote).joined(separator: " ")
        // Not `|| true`: a push reported this directory as the agent's cwd, so
        // starting in $HOME instead would run the agent against the wrong tree
        // while the JSON still claims it synced.
        let enter = workDirectory.map { "cd \(shellQuote($0)) || exit 1; " } ?? ""
        return [
            "bash", "-lc",
            "cd \"$HOME\"; \(enter)export PATH=\"$HOME/.npm-global/bin:$HOME/.bun/bin:$HOME/.local/bin:$PATH\"; exec \(joined)",
        ]
    }

    func runVMRouteCommand(rest: [String], client: SocketClient, jsonOutput: Bool) throws {
        if rest.contains("--help") || rest.contains("-h") {
            print(Self.vmRouteUsage)
            return
        }
        var cwdOption: String?
        var forceNew = false
        var provision = false
        var sizeOption: String?
        var index = 0
        while index < rest.count {
            let arg = rest[index]
            func takeValue() throws -> String {
                guard index + 1 < rest.count else {
                    throw CLIError(message: "\(arg) requires a value\n\n\(Self.vmRouteUsage)")
                }
                index += 1
                return rest[index]
            }
            switch arg {
            case "--cwd": cwdOption = try takeValue()
            case "--new": forceNew = true
            case "--provision": provision = true
            case "--size": sizeOption = try takeValue()
            case "--json": break
            default:
                throw CLIError(message: "Unknown option \(arg)\n\n\(Self.vmRouteUsage)")
            }
            index += 1
        }
        var memoryMb: Int?
        if let sizeOption {
            guard let parsed = Self.parseCloudVMSize(sizeOption) else {
                throw CLIError(message: "vm route: unknown size '\(sizeOption)'. Sizes: 20g (the plan machine) or memory in MB (at least 512).")
            }
            memoryMb = parsed
        }
        let workDirectory = cwdOption.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            ?? FileManager.default.currentDirectoryPath
        let selection = try selectVMForRun(
            machineOverride: nil,
            forceNew: forceNew,
            memoryMb: memoryMb,
            workDirectory: workDirectory,
            allowProvision: provision,
            client: client
        )
        if jsonOutput {
            var payload: [String: Any] = [
                "created": selection.created,
                "reason": selection.reason,
                "would_provision": selection.wouldProvision,
                "directory": workDirectory,
            ]
            payload["machine"] = selection.wouldProvision ? NSNull() : selection.id
            print(jsonString(payload))
            return
        }
        if selection.wouldProvision {
            print(String(
                format: String(localized: "cli.vm.route.wouldProvision", defaultValue: "No pool machine is free for %@ \u{2014} `cmux vm run` would provision a fresh one (add --provision to create it now)."),
                workDirectory
            ))
            return
        }
        print("machine=\(selection.id) created=\(selection.created)")
        print("reason: \(selection.reason)")
    }

    func runVMAgentCommand(rest: [String], client: SocketClient, jsonOutput: Bool) throws {
        if CmuxTuiRemoteRouting.vmAgentRequestsHelp(rest) {
            print(Self.vmAgentUsage)
            return
        }
        var flags: [String] = rest
        var agentArgs: [String] = []
        if let separator = rest.firstIndex(of: "--") {
            flags = Array(rest[..<separator])
            agentArgs = Array(rest[(separator + 1)...])
        }
        var agent: String?
        var machineOverride: String?
        var sync = false
        var cwdOption: String?
        var nameOption: String?
        var noOpen = false
        var remoteWorkspaceOption: String?
        var forceNew = false
        var sizeOption: String?
        var wait = false
        var wantOutput = false
        var waitTimeoutOption: String?
        var index = 0
        while index < flags.count {
            let arg = flags[index]
            func takeValue() throws -> String {
                guard index + 1 < flags.count else {
                    throw CLIError(message: "\(arg) requires a value\n\n\(Self.vmAgentUsage)")
                }
                index += 1
                return flags[index]
            }
            switch arg {
            case "--agent": agent = try takeValue().lowercased()
            case "--machine": machineOverride = try takeValue()
            case "--sync": sync = true
            case "--cwd": cwdOption = try takeValue()
            case "--name": nameOption = try takeValue()
            case "--no-open": noOpen = true
            case "--remote-workspace": remoteWorkspaceOption = try takeValue()
            case "--new": forceNew = true
            case "--size": sizeOption = try takeValue()
            case "--wait": wait = true
            case "--output":
                wait = true
                wantOutput = true
            case "--timeout": waitTimeoutOption = try takeValue()
            case "--json": break
            default:
                throw CLIError(message: "Unknown option \(arg)\n\n\(Self.vmAgentUsage)")
            }
            index += 1
        }
        guard let agent, Self.vmAgentNames.contains(agent) else {
            throw CLIError(message: "vm agent: --agent must be one of \(Self.vmAgentNames.joined(separator: ", "))\n\n\(Self.vmAgentUsage)")
        }
        guard let argv = Self.vmAgentArgv(agent: agent, args: agentArgs) else {
            throw CLIError(message: Self.vmAgentUsage)
        }
        var memoryMb: Int?
        if let sizeOption {
            guard let parsed = Self.parseCloudVMSize(sizeOption) else {
                throw CLIError(message: "vm agent: unknown size '\(sizeOption)'. Sizes: 20g (the plan machine) or memory in MB (at least 512).")
            }
            memoryMb = parsed
        }
        var waitTimeoutSeconds = 0
        if let waitTimeoutOption {
            guard wait else {
                throw CLIError(message: "vm agent: --timeout belongs to --wait\n\n\(Self.vmAgentUsage)")
            }
            guard let parsed = Int(waitTimeoutOption), parsed >= 0 else {
                throw CLIError(message: "vm agent: --timeout must be a whole number of seconds (0 = no limit; got '\(waitTimeoutOption)')\n\n\(Self.vmAgentUsage)")
            }
            waitTimeoutSeconds = parsed
        }
        let workDirectory = cwdOption.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            ?? FileManager.default.currentDirectoryPath

        if sync {
            // Help stays readable; refuse the transfer before VM selection.
            try Self.throwIfFileTransferIsManagedOff()
        }

        let selection = try selectVMForRun(
            machineOverride: machineOverride,
            forceNew: forceNew,
            memoryMb: memoryMb,
            workDirectory: workDirectory,
            client: client
        )
        cliWriteStderr("[cmux vm agent] \(selection.id) (\(selection.reason))\n")
        Self.saveVMRunBinding(workKey: Self.vmRunWorkKey(forDirectory: workDirectory), machine: selection.id)

        var syncedRemoteDir: String?
        if sync {
            let basename = (workDirectory as NSString).lastPathComponent
            let remoteDir = "work/\(basename)"
            try runVMPushCommand(
                rest: [selection.id, workDirectory, remoteDir],
                client: client,
                jsonOutput: false,
                quiet: true
            )
            syncedRemoteDir = remoteDir
        }
        // Reported, not requested: the daemon starts the terminal in its own home and the
        // command cd's from there, so the CLI never has to know which user owns the machine.
        let remoteCwd = syncedRemoteDir.map { "~/\($0)" } ?? "~"

        let name = nameOption ?? Self.vmAgentTerminalName(agent: agent, args: agentArgs)
        // The agent is a terminal resource on the machine (`surface.new_terminal`): it lives
        // in the machine's cmux-tui session, shows up in `cmux vm tree`, and opens locally as a
        // pane unless --no-open.
        var params: [String: Any] = [
            "machine": selection.id,
            "command": vmAgentShellCommand(argv: argv, workDirectory: syncedRemoteDir),
            "name": name,
            "open": !noOpen,
        ]
        // --remote-workspace: land the agent's terminal in a staged machine
        // workspace (from `vm workspace new --no-open` or `vm tree`), so it joins
        // that group instead of the detached pool.
        if let remoteWorkspaceOption, !remoteWorkspaceOption.isEmpty {
            params["remote_workspace_id"] = remoteWorkspaceOption
        }
        let response = try client.sendV2(method: "surface.new_terminal", params: params, responseTimeout: 240)
        let terminalId = (response["terminal_id"] as? String) ?? "?"
        let workspaceId = (response["remote_workspace_id"] as? String) ?? "?"
        let surfaceId = (response["surface_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let reattach = "cmux vm open \(selection.id)/\(workspaceId)/\(terminalId)"
        var payload: [String: Any] = [
            "machine": selection.id,
            "created": selection.created,
            "reason": selection.reason,
            "agent": agent,
            "command": argv,
            "name": name,
            "terminal_id": terminalId,
            "workspace_id": workspaceId,
            "cwd": remoteCwd,
            "reattach": reattach,
        ]
        if let surfaceId { payload["surface_id"] = surfaceId }
        if let syncedRemoteDir { payload["synced_to"] = syncedRemoteDir }
        let startedLine = String(
            format: String(localized: "cli.vm.agent.started", defaultValue: "Started %1$@ on %2$@ \u{2014} terminal %3$@ in workspace %4$@ (detached: it keeps running if the pane closes)."),
            agent, selection.id, terminalId, workspaceId
        )
        let reattachLine = String(
            format: String(localized: "cli.vm.agent.reattach", defaultValue: "Reattach: cmux vm open %1$@/%2$@/%3$@"),
            selection.id, workspaceId, terminalId
        )

        guard wait else {
            if jsonOutput {
                print(jsonString(payload))
                return
            }
            print(startedLine)
            print(reattachLine)
            if let surfaceId {
                print("OK surface=\(surfaceId) terminal=\(terminalId) workspace=\(workspaceId)")
            }
            return
        }

        // --wait: the launch report moves to stderr so stdout carries only the agent's
        // output (--output) or the exit line; the JSON form is one object at the end.
        guard terminalId != "?" else {
            throw CLIError(message: "vm agent: the app did not return a terminal id for the agent, so there is nothing to wait on. It may still be running; check `cmux vm tree \(selection.id)`.")
        }
        if !jsonOutput {
            cliWriteStderr(startedLine + "\n")
        }
        cliWriteStderr(String(
            format: String(localized: "cli.vm.agent.waiting", defaultValue: "Waiting for %1$@ to finish (Ctrl-C stops waiting; the agent keeps running — %2$@).\n"),
            terminalId, reattach
        ))
        let waitStarted = Date()
        let exit = try waitForVMTerminalExit(
            machine: selection.id,
            terminalID: terminalId,
            timeoutSeconds: waitTimeoutSeconds,
            client: client
        )
        let waited = Int(Date().timeIntervalSince(waitStarted).rounded())
        var outputText: String?
        if wantOutput {
            outputText = try readVMTerminalOutput(machine: selection.id, terminalID: terminalId, client: client)
        }
        if jsonOutput {
            payload["exited"] = exit != nil
            payload["exit"] = exit?["outcome"] ?? NSNull()
            payload["waited_seconds"] = waited
            if let outputText { payload["output"] = outputText }
            print(jsonString(payload))
        } else {
            if let outputText, !outputText.isEmpty {
                print(outputText, terminator: outputText.hasSuffix("\n") ? "" : "\n")
            }
            if let exit {
                let summary = Self.vmTerminalExitSummary(exit)
                if wantOutput {
                    cliWriteStderr(summary + "\n")
                } else {
                    print(summary)
                }
            }
        }
        guard let exit else {
            throw CLIError(message: "\(agent) on \(selection.id) is still running after \(waited)s (not stopped). Reattach: \(reattach) — or keep waiting: cmux vm terminal wait-exit \(selection.id) \(terminalId) --timeout 3600", exitCode: 1)
        }
        let code = Self.vmTerminalExitCode(exit)
        if code != 0 {
            throw CLIError(message: "exit \(code)", exitCode: code)
        }
    }

    // MARK: - until-done helpers (shared by `vm agent --wait` and `vm dev`)

    /// One `vm.terminal_wait_exit` round trip never exceeds this, so a long agent run is
    /// many short waits and no single socket call can time out on it.
    static let vmAgentWaitSliceMs = 30_000

    /// Blocks until the terminal's process exits and returns the `vm.terminal_wait_exit`
    /// result, or nil when `timeoutSeconds` (> 0) elapsed first. Errors from the socket
    /// (machine asleep, terminal gone) propagate.
    func waitForVMTerminalExit(machine: String, terminalID: String, timeoutSeconds: Int, client: SocketClient) throws -> [String: Any]? {
        let deadline = timeoutSeconds > 0 ? Date().addingTimeInterval(TimeInterval(timeoutSeconds)) : nil
        while true {
            var sliceMs = Self.vmAgentWaitSliceMs
            if let deadline {
                let remaining = deadline.timeIntervalSinceNow
                if remaining <= 0 { return nil }
                sliceMs = min(sliceMs, max(1_000, Int(remaining * 1000)))
            }
            let response = try client.sendV2(
                method: "vm.terminal_wait_exit",
                params: ["id": machine, "terminal_id": terminalID, "timeout_ms": sliceMs],
                responseTimeout: TimeInterval(sliceMs / 1000 + 20)
            )
            if (response["state"] as? String) == "exited" {
                return response
            }
        }
    }

    /// The terminal's whole retained output: `vm.terminal_output` paged by `next_offset`
    /// until the daemon reports `complete`.
    func readVMTerminalOutput(machine: String, terminalID: String, client: SocketClient, after initialOffset: Int = 0, maxBytes: Int? = nil) throws -> String {
        var text = ""
        var after = initialOffset
        var pages = 0
        while true {
            var params: [String: Any] = ["id": machine, "terminal_id": terminalID, "after": after]
            if let maxBytes { params["max_bytes"] = maxBytes }
            let response = try client.sendV2(
                method: "vm.terminal_output",
                params: params,
                responseTimeout: 120
            )
            text += (response["text"] as? String) ?? ""
            let next = (response["next_offset"] as? Int) ?? (response["next_offset"] as? String).flatMap(Int.init)
            guard let complete = response["complete"] as? Bool else {
                throw CLIError(message: String(localized: "cli.vm.output.invalidPage", defaultValue: "The machine returned an invalid output page. Reconnect and retry."))
            }
            pages += 1
            if complete { return text }
            guard let next, next > after, pages < 4096 else {
                throw CLIError(message: String(localized: "cli.vm.output.incomplete", defaultValue: "The machine's output could not be read completely. Reconnect and retry."))
            }
            after = next
        }
    }

    /// The exit status to pass through for a `vm.terminal_wait_exit` result: the process's
    /// own code for a normal exit (clamped to 1…255 when out of range), 1 for a signal or
    /// an unknown outcome.
    static func vmTerminalExitCode(_ response: [String: Any]) -> Int32 {
        let outcome = (response["outcome"] as? [String: Any]) ?? [:]
        guard (outcome["kind"] as? String) == "exit" else { return 1 }
        let code = (outcome["code"] as? Int) ?? 1
        if code == 0 { return 0 }
        return Int32((1...255).contains(code) ? code : 1)
    }
}
