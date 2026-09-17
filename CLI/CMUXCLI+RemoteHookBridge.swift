import Foundation

extension CMUXCLI {
    // The nested installer must expire before the app bridge's process deadline.
    private static let remoteHookInstallerTimeout: TimeInterval = 105
    private static let remoteHookInstallerMaximumReturnedBytes = 1024 * 1024
    // `/bin/sh` uses 512-byte blocks; two 16 MiB file caps bound aggregate capture at 32 MiB.
    private static let remoteHookInstallerOutputLimitScript = "ulimit -f 32768 || exit 125; exec \"$@\""

    private static let remoteHookBridgeMaximumConfigurationBytes = 8 * 1024 * 1024
    private static let remoteHookBridgeMaximumPayloadBytes = 16 * 1024 * 1024

    func runRemoteHookBridgeCommand(_ arguments: [String]) throws -> Bool {
        guard let command = arguments.first?.lowercased(), command.hasPrefix("__remote-") else {
            return false
        }
        switch command {
        case "__remote-catalog":
            guard arguments.count == 1 else { throw Self.remoteHookBridgeError("invalid_catalog_request") }
            try Self.printRemoteHookJSON(Self.agentDefs.map(Self.remoteHookDescriptor))
        case "__remote-describe":
            guard arguments.count == 2, let definition = Self.agentDef(named: arguments[1]) else {
                throw Self.remoteHookBridgeError("unknown_hooks_target")
            }
            try Self.printRemoteHookJSON(Self.remoteHookDescriptor(definition))
        case "__remote-configure":
            guard arguments.count == 1 else { throw Self.remoteHookBridgeError("invalid_configure_request") }
            let input = FileHandle.standardInput.readDataToEndOfFile()
            guard input.count <= Self.remoteHookBridgeMaximumPayloadBytes else {
                throw Self.remoteHookBridgeError("configuration_too_large")
            }
            let snapshot: RemoteHookSnapshot
            do {
                snapshot = try JSONDecoder().decode(RemoteHookSnapshot.self, from: input)
            } catch {
                throw Self.remoteHookBridgeError("invalid_configuration_snapshot")
            }
            try Self.printRemoteHookJSON(try buildRemoteHookPlan(snapshot))
        default:
            throw Self.remoteHookBridgeError("unknown_bridge_command")
        }
        return true
    }

    private static func remoteHookDescriptor(_ definition: AgentHookDef) -> RemoteHookDescriptor {
        let environment = ProcessInfo.processInfo.environment
        let home = normalizedRemoteHookPath(environment["HOME"] ?? NSHomeDirectory())
        let configDirectory = normalizedRemoteHookPath(definition.resolvedConfigDir())
        var paths = [
            URL(fileURLWithPath: configDirectory, isDirectory: true)
                .appendingPathComponent(definition.configFile, isDirectory: false).path,
        ]
        var recursivePaths: [String] = []
        switch definition.name {
        case "codex":
            paths.append(URL(fileURLWithPath: configDirectory).appendingPathComponent("config.toml").path)
            let scriptsDirectory = URL(fileURLWithPath: home).appendingPathComponent(".cmux/hooks", isDirectory: true).path
            paths.append(scriptsDirectory)
            recursivePaths.append(scriptsDirectory)
        case "grok":
            paths.append(URL(fileURLWithPath: configDirectory).appendingPathComponent("cmux.json").path)
        case "opencode":
            paths.append(URL(fileURLWithPath: configDirectory).appendingPathComponent("opencode.json").path)
            paths.append(URL(fileURLWithPath: configDirectory).appendingPathComponent("plugins/cmux-feed.js").path)
            let cwd = normalizedRemoteHookPath(environment["PWD"] ?? home)
            paths.append(URL(fileURLWithPath: cwd).appendingPathComponent(".opencode/plugins/cmux-feed.js").path)
        case "hermes-agent":
            paths.append(URL(fileURLWithPath: configDirectory).appendingPathComponent("shell-hooks-allowlist.json").path)
        case "kimi":
            let legacyDirectory = environment["KIMI_CODE_HOME"].flatMap(nonEmptyRemoteHookValue)
                .map(normalizedRemoteHookPath)
                ?? URL(fileURLWithPath: home).appendingPathComponent(".kimi-code", isDirectory: true).path
            paths.append(URL(fileURLWithPath: legacyDirectory).appendingPathComponent(definition.configFile).path)
        default:
            break
        }
        return RemoteHookDescriptor(
            name: definition.name,
            aliases: definition.aliases.sorted(),
            binaryName: definition.binaryName,
            configDirectory: configDirectory,
            installWhenConfigMissing: definition.createConfigDirIfMissing
                || ["opencode", "pi", "amp", "rovodev"].contains(definition.name),
            snapshotPaths: Array(Set(paths.map(normalizedRemoteHookPath))).sorted(),
            recursivePaths: Array(Set(recursivePaths.map(normalizedRemoteHookPath))).sorted()
        )
    }

    private func buildRemoteHookPlan(_ snapshot: RemoteHookSnapshot) throws -> RemoteHookPlan {
        guard let definition = Self.agentDef(named: snapshot.agent) else {
            throw Self.remoteHookBridgeError("unknown_hooks_target")
        }
        guard snapshot.action == "install" || snapshot.action == "uninstall" else {
            throw Self.remoteHookBridgeError("invalid_configuration_action")
        }
        let allowedArguments = snapshot.arguments.filter { $0 == "--project" }
        guard snapshot.arguments.allSatisfy({ $0 == "--project" || $0 == "--yes" || $0 == "-y" }),
              definition.name == "opencode" || allowedArguments.isEmpty else {
            throw Self.remoteHookBridgeError("invalid_configuration_arguments")
        }

        let descriptor = Self.remoteHookDescriptor(definition)
        var seenPaths: Set<String> = []
        var before: [String: RemoteHookSnapshotEntry] = [:]
        for entry in snapshot.entries {
            let path = Self.normalizedRemoteHookPath(entry.path)
            guard seenPaths.insert(path).inserted else {
                throw Self.remoteHookBridgeError("duplicate_snapshot_path")
            }
            if entry.kind == "file" {
                before[path] = entry
            }
        }
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-remote-hooks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        try Self.restoreRemoteHookSnapshot(snapshot.entries, descriptor: descriptor, under: temporaryDirectory)
        let result = try runRemoteHookInstaller(
            definition: definition,
            action: snapshot.action,
            arguments: allowedArguments,
            descriptor: descriptor,
            temporaryDirectory: temporaryDirectory
        )
        let after = try Self.remoteHookFiles(descriptor: descriptor, under: temporaryDirectory)
        var mutations: [RemoteHookMutation] = []
        for path in Set(before.keys).union(after.keys).sorted() {
            if let current = after[path] {
                let previous = before[path]
                if previous?.contentBase64 != current.contentBase64 || previous?.mode != current.mode {
                    mutations.append(RemoteHookMutation(
                        path: path,
                        delete: false,
                        contentBase64: current.contentBase64,
                        mode: current.mode
                    ))
                }
            } else if before[path] != nil {
                mutations.append(RemoteHookMutation(path: path, delete: true, contentBase64: nil, mode: nil))
            }
        }
        return RemoteHookPlan(
            stdoutBase64: Self.remoteHookInstallerOutput(result.stdout, temporaryDirectory: temporaryDirectory).base64EncodedString(),
            stderrBase64: Self.remoteHookInstallerOutput(result.stderr, temporaryDirectory: temporaryDirectory).base64EncodedString(),
            exitCode: result.status,
            mutations: mutations
        )
    }

    private static func restoreRemoteHookSnapshot(
        _ entries: [RemoteHookSnapshotEntry],
        descriptor: RemoteHookDescriptor,
        under root: URL
    ) throws {
        var totalBytes = 0
        for entry in entries.sorted(by: { ($0.kind == "directory" ? 0 : 1, $0.path) < ($1.kind == "directory" ? 0 : 1, $1.path) }) {
            let path = normalizedRemoteHookPath(entry.path)
            guard remoteHookPath(path, descriptor: descriptor) else {
                throw remoteHookBridgeError("snapshot_path_out_of_scope")
            }
            let mirrorURL = try remoteHookMirrorURL(for: path, under: root)
            if entry.kind == "directory" {
                try FileManager.default.createDirectory(at: mirrorURL, withIntermediateDirectories: true)
                try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: entry.mode)], ofItemAtPath: mirrorURL.path)
                continue
            }
            guard entry.kind == "file", let encoded = entry.contentBase64,
                  let content = Data(base64Encoded: encoded) else {
                throw remoteHookBridgeError("invalid_snapshot_file")
            }
            totalBytes += content.count
            guard totalBytes <= remoteHookBridgeMaximumConfigurationBytes else {
                throw remoteHookBridgeError("configuration_too_large")
            }
            try FileManager.default.createDirectory(at: mirrorURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: mirrorURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: entry.mode)], ofItemAtPath: mirrorURL.path)
        }
    }

    private func runRemoteHookInstaller(
        definition: AgentHookDef,
        action: String,
        arguments: [String],
        descriptor: RemoteHookDescriptor,
        temporaryDirectory: URL
    ) throws -> (stdout: Data, stderr: Data, status: Int32) {
        guard let executablePath = CommandLine.arguments.first, executablePath.hasPrefix("/") else {
            throw Self.remoteHookBridgeError("bundled_cli_unavailable")
        }
        let outputURL = temporaryDirectory.appendingPathComponent(".bridge-stdout")
        let errorURL = temporaryDirectory.appendingPathComponent(".bridge-stderr")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        let errorHandle = try FileHandle(forWritingTo: errorURL)
        defer {
            try? outputHandle.close()
            try? errorHandle.close()
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            Self.remoteHookInstallerOutputLimitScript,
            "cmux-remote-hook-installer",
            executablePath,
            "hooks",
            definition.name,
            action,
            "--yes",
        ] + arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputHandle
        process.standardError = errorHandle
        var environment = ProcessInfo.processInfo.environment
        let remoteHome = Self.normalizedRemoteHookPath(environment["HOME"] ?? NSHomeDirectory())
        environment["HOME"] = try Self.remoteHookMirrorURL(for: remoteHome, under: temporaryDirectory).path
        environment["CMUX_HOOK_RELAY_BRIDGE_CHILD"] = "1"
        environment["CMUX_HOOK_INSTALL_PATH_PREFIX"] = temporaryDirectory.standardizedFileURL.path
        environment["CMUX_HOOK_INSTALL_CLI_PATH"] = environment["CMUX_BUNDLED_CLI_PATH"]
            ?? URL(fileURLWithPath: remoteHome).appendingPathComponent(".cmux/bin/cmux").path
        if let override = definition.configDirEnvOverride {
            let mirroredConfig = try Self.remoteHookMirrorURL(for: descriptor.configDirectory, under: temporaryDirectory)
            environment[override] = definition.configDirEnvOverrideSubpath == nil
                ? mirroredConfig.path
                : mirroredConfig.deletingLastPathComponent().path
        }
        if definition.name == "omp" {
            environment["PI_CODING_AGENT_DIR"] = try Self.remoteHookMirrorURL(for: descriptor.configDirectory, under: temporaryDirectory).path
            environment.removeValue(forKey: "PI_CONFIG_DIR")
        } else if definition.name == "campfire" {
            environment["CAMPFIRE_CODING_AGENT_DIR"] = try Self.remoteHookMirrorURL(for: descriptor.configDirectory, under: temporaryDirectory).path
        } else if definition.name == "kimi" {
            let activePath = URL(fileURLWithPath: descriptor.configDirectory)
                .appendingPathComponent(definition.configFile).path
            let legacyPath = descriptor.snapshotPaths.first {
                $0 != activePath && URL(fileURLWithPath: $0).lastPathComponent == definition.configFile
            }
            if let legacyPath {
                environment["KIMI_CODE_HOME"] = try Self.remoteHookMirrorURL(
                    for: URL(fileURLWithPath: legacyPath).deletingLastPathComponent().path,
                    under: temporaryDirectory
                ).path
            }
        }
        process.environment = environment
        let remoteCWD = Self.normalizedRemoteHookPath(environment["PWD"] ?? remoteHome)
        let mirroredCWD = try Self.remoteHookMirrorURL(for: remoteCWD, under: temporaryDirectory)
        try FileManager.default.createDirectory(at: mirroredCWD, withIntermediateDirectories: true)
        process.currentDirectoryURL = mirroredCWD

        do {
            try process.run()
        } catch {
            throw Self.remoteHookBridgeError("installer_launch_failed")
        }
        let exited: Bool
        do {
            exited = try waitForProcessExit(process, timeout: Self.remoteHookInstallerTimeout)
        } catch {
            terminateRemoteHookInstaller(process)
            throw Self.remoteHookBridgeError("installer_monitor_failed")
        }
        guard exited else {
            terminateRemoteHookInstaller(process)
            throw Self.remoteHookBridgeError("installer_timed_out")
        }
        try outputHandle.synchronize()
        try errorHandle.synchronize()
        let outputSize = try remoteHookInstallerOutputSize(at: outputURL)
        let errorSize = try remoteHookInstallerOutputSize(at: errorURL)
        guard outputSize + errorSize <= Self.remoteHookInstallerMaximumReturnedBytes else {
            throw Self.remoteHookBridgeError("installer_output_too_large")
        }
        return (
            try Data(contentsOf: outputURL),
            try Data(contentsOf: errorURL),
            process.terminationStatus
        )
    }

    private func remoteHookInstallerOutputSize(at url: URL) throws -> Int {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let size = values.fileSize else {
            throw Self.remoteHookBridgeError("invalid_installer_output")
        }
        return size
    }

    private func terminateRemoteHookInstaller(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        if ((try? waitForProcessExit(process, timeout: 2)) ?? false) == false {
            kill(process.processIdentifier, SIGKILL)
            _ = try? waitForProcessExit(process, timeout: 1)
        }
    }

    private static func remoteHookFiles(
        descriptor: RemoteHookDescriptor,
        under root: URL
    ) throws -> [String: RemoteHookSnapshotEntry] {
        var result: [String: RemoteHookSnapshotEntry] = [:]
        var totalBytes = 0
        for remoteRoot in descriptor.snapshotPaths {
            let mirrorRoot = try remoteHookMirrorURL(for: remoteRoot, under: root)
            var isDirectory = ObjCBool(false)
            guard FileManager.default.fileExists(atPath: mirrorRoot.path, isDirectory: &isDirectory) else { continue }
            let rootValues = try mirrorRoot.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard rootValues.isSymbolicLink != true else {
                throw remoteHookBridgeError("installer_produced_symlink")
            }
            let candidates: [URL]
            if isDirectory.boolValue {
                guard descriptor.recursivePaths.contains(normalizedRemoteHookPath(remoteRoot)) else {
                    continue
                }
                let enumerator = FileManager.default.enumerator(
                    at: mirrorRoot,
                    includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                    options: []
                )
                candidates = (enumerator?.allObjects as? [URL]) ?? []
            } else {
                candidates = [mirrorRoot]
            }
            for candidate in candidates {
                let values = try candidate.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isSymbolicLink != true else {
                    throw remoteHookBridgeError("installer_produced_symlink")
                }
                guard values.isRegularFile == true else { continue }
                let content = try Data(contentsOf: candidate)
                totalBytes += content.count
                guard totalBytes <= remoteHookBridgeMaximumConfigurationBytes else {
                    throw remoteHookBridgeError("install_plan_too_large")
                }
                let attributes = try FileManager.default.attributesOfItem(atPath: candidate.path)
                let mode = (attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o600
                let path = try remoteHookOriginalPath(for: candidate, under: root)
                result[path] = RemoteHookSnapshotEntry(
                    path: path,
                    kind: "file",
                    contentBase64: content.base64EncodedString(),
                    mode: mode
                )
            }
        }
        return result
    }

    private static func remoteHookMirrorURL(for path: String, under root: URL) throws -> URL {
        let normalized = normalizedRemoteHookPath(path)
        guard normalized.hasPrefix("/"), !normalized.contains("\0") else {
            throw remoteHookBridgeError("configuration_path_not_absolute")
        }
        return root.appendingPathComponent(String(normalized.dropFirst()), isDirectory: false).standardizedFileURL
    }

    private static func remoteHookOriginalPath(for mirrorURL: URL, under root: URL) throws -> String {
        let rootPath = root.standardizedFileURL.path + "/"
        let path = mirrorURL.standardizedFileURL.path
        guard path.hasPrefix(rootPath) else { throw remoteHookBridgeError("invalid_install_plan_path") }
        return "/" + path.dropFirst(rootPath.count)
    }

    private static func remoteHookInstallerOutput(_ data: Data, temporaryDirectory: URL) -> Data {
        guard var output = String(data: data, encoding: .utf8) else { return data }
        output = output.replacingOccurrences(of: temporaryDirectory.standardizedFileURL.path, with: "")
        return Data(output.utf8)
    }

    private static func remoteHookPath(_ path: String, descriptor: RemoteHookDescriptor) -> Bool {
        if descriptor.snapshotPaths.contains(where: { path == normalizedRemoteHookPath($0) }) { return true }
        return descriptor.recursivePaths.contains { root in
            path.hasPrefix(normalizedRemoteHookPath(root) + "/")
        }
    }

    private static func normalizedRemoteHookPath(_ path: String) -> String {
        URL(fileURLWithPath: NSString(string: path).expandingTildeInPath).standardizedFileURL.path
    }

    static func remoteHookInstallDestinationPath(
        _ path: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        guard environment["CMUX_HOOK_RELAY_BRIDGE_CHILD"] == "1",
              let prefix = environment["CMUX_HOOK_INSTALL_PATH_PREFIX"],
              path.hasPrefix(prefix + "/") else { return path }
        return "/" + path.dropFirst(prefix.count + 1)
    }

    private static func nonEmptyRemoteHookValue(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func printRemoteHookJSON<T: Encodable>(_ value: T) throws {
        let data = try JSONEncoder.remoteHookBridgeEncoder.encode(value)
        guard let string = String(data: data, encoding: .utf8) else {
            throw remoteHookBridgeError("response_encoding_failed")
        }
        print(string)
    }

    private static func remoteHookBridgeError(_ detail: String) -> CLIError {
        CLIError(message: String.localizedStringWithFormat(
            String(
                localized: "cli.hooks.remoteBridge.error",
                defaultValue: "Remote hook bridge failed: %@"
            ),
            detail
        ))
    }
}

private extension JSONEncoder {
    static var remoteHookBridgeEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
