import Foundation

nonisolated struct RemoteHookInvocationBridge: Sendable {
    struct BridgeError: Error {
        let code: String
        let message: String
    }

    private struct Invocation: Sendable {
        let arguments: [String]
        let environment: [String: String]
        let input: Data
    }

    private struct TransferMetadata: Codable, Sendable {
        let arguments: [String]
        let environment: [String: String]
    }

    private let maximumInputBytes = 8 * 1024 * 1024
    private let maximumChunkBytes = 6 * 1024
    private let staleTransferAge: TimeInterval = 300

    func handle(
        method: String,
        params: [String: Any],
        localSocketPath: String
    ) -> Result<[String: Any], BridgeError> {
        do {
            switch method {
            case "hooks.invoke":
                let invocation = try decodeInvocation(params: params)
                return .success(try run(invocation, localSocketPath: localSocketPath))
            case "hooks.invoke.begin":
                let invocation = try decodeInvocation(params: params, requireInput: false)
                return .success(["transfer_id": try beginTransfer(invocation)])
            case "hooks.invoke.append":
                let transferID = try requiredString("transfer_id", params: params)
                let chunk = try decodedData("chunk_base64", params: params)
                guard chunk.count <= maximumChunkBytes else {
                    throw bridgeError(
                        "invalid_params",
                        key: "socket.hooks.remoteBridge.chunkTooLarge",
                        fallback: "Remote hook payload chunk is too large."
                    )
                }
                try append(chunk, toTransfer: transferID)
                return .success(["appended": true])
            case "hooks.invoke.execute":
                let transferID = try requiredString("transfer_id", params: params)
                let invocation = try takeTransfer(transferID)
                return .success(try run(invocation, localSocketPath: localSocketPath))
            default:
                throw bridgeError(
                    "method_not_found",
                    key: "socket.hooks.remoteBridge.invalidMethod",
                    fallback: "Unknown remote hook bridge method."
                )
            }
        } catch let error as BridgeError {
            return .failure(error)
        } catch {
            return .failure(bridgeError(
                "internal_error",
                key: "socket.hooks.remoteBridge.failed",
                fallback: "The remote hook bridge failed."
            ))
        }
    }

    private func decodeInvocation(params: [String: Any], requireInput: Bool = true) throws -> Invocation {
        guard let arguments = params["arguments"] as? [String],
              !arguments.isEmpty,
              arguments.count <= 32,
              arguments.allSatisfy({ $0.utf8.count <= 4_096 }),
              Self.argumentsAreAllowed(arguments) else {
            throw bridgeError(
                "invalid_params",
                key: "socket.hooks.remoteBridge.invalidArguments",
                fallback: "Remote hook arguments are invalid."
            )
        }
        var environment = (params["environment"] as? [String: String]) ?? [:]
        if let workspaceID = params["workspace_id"] as? String {
            environment["CMUX_WORKSPACE_ID"] = workspaceID
        }
        if let surfaceID = params["surface_id"] as? String {
            environment["CMUX_SURFACE_ID"] = surfaceID
        }
        guard environment.count <= 32,
              environment.allSatisfy({ $0.key.utf8.count <= 128 && $0.value.utf8.count <= 16_384 }) else {
            throw bridgeError(
                "invalid_params",
                key: "socket.hooks.remoteBridge.invalidEnvironment",
                fallback: "Remote hook environment is invalid."
            )
        }
        if arguments.first?.hasPrefix("__remote-") == true,
           environment["HOME"]?.hasPrefix("/") != true {
            throw bridgeError(
                "invalid_params",
                key: "socket.hooks.remoteBridge.invalidEnvironment",
                fallback: "Remote hook environment is invalid."
            )
        }
        let input: Data
        if requireInput || params["stdin_base64"] != nil {
            input = try decodedData("stdin_base64", params: params)
        } else {
            input = Data()
        }
        guard input.count <= maximumInputBytes else {
            throw bridgeError(
                "invalid_params",
                key: "socket.hooks.remoteBridge.payloadTooLarge",
                fallback: "Remote hook payload exceeds the relay limit."
            )
        }
        return Invocation(arguments: arguments, environment: environment, input: input)
    }

    private static func argumentsAreAllowed(_ arguments: [String]) -> Bool {
        guard let first = arguments.first?.lowercased() else { return false }
        if first.hasPrefix("__remote-") {
            switch first {
            case "__remote-catalog": return arguments.count == 1
            case "__remote-describe": return arguments.count == 2
            case "__remote-configure": return arguments.count == 1
            default: return false
            }
        }
        let prohibitedCommands: Set<String> = ["install", "setup", "uninstall"]
        guard !prohibitedCommands.contains(first) else { return false }
        guard arguments.count >= 2 else { return false }
        let prohibitedActions: Set<String> = [
            "install", "uninstall", "setup", "remove", "install-hooks", "uninstall-hooks",
        ]
        return !prohibitedActions.contains(arguments[1].lowercased())
    }

    private func beginTransfer(_ invocation: Invocation) throws -> String {
        try FileManager.default.createDirectory(
            at: transferRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: transferRoot.path
        )
        removeStaleTransfers()
        let transferID = UUID().uuidString
        let directory = transferRoot.appendingPathComponent(transferID, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let metadata = TransferMetadata(
            arguments: invocation.arguments,
            environment: invocation.environment
        )
        try writePrivate(JSONEncoder().encode(metadata), to: directory.appendingPathComponent("metadata.json"))
        try writePrivate(Data(), to: directory.appendingPathComponent("stdin"))
        return transferID
    }

    private func append(_ chunk: Data, toTransfer transferID: String) throws {
        let directory = try existingTransferDirectory(for: transferID)
        let inputURL = directory.appendingPathComponent("stdin")
        let inputHandle = try FileHandle(forWritingTo: inputURL)
        defer { try? inputHandle.close() }
        let currentSize = try inputHandle.seekToEnd()
        guard currentSize <= UInt64(maximumInputBytes - chunk.count) else {
            try? FileManager.default.removeItem(at: directory)
            throw bridgeError(
                "invalid_params",
                key: "socket.hooks.remoteBridge.invalidTransfer",
                fallback: "Remote hook payload transfer is missing or too large."
            )
        }
        try inputHandle.write(contentsOf: chunk)
    }

    private func takeTransfer(_ transferID: String) throws -> Invocation {
        let directory = try existingTransferDirectory(for: transferID)
        defer { try? FileManager.default.removeItem(at: directory) }
        let metadata = try JSONDecoder().decode(
            TransferMetadata.self,
            from: Data(contentsOf: directory.appendingPathComponent("metadata.json"))
        )
        let input = try Data(contentsOf: directory.appendingPathComponent("stdin"))
        guard input.count <= maximumInputBytes else {
            throw bridgeError(
                "invalid_params",
                key: "socket.hooks.remoteBridge.invalidTransfer",
                fallback: "Remote hook payload transfer is missing or too large."
            )
        }
        return Invocation(arguments: metadata.arguments, environment: metadata.environment, input: input)
    }

    private var transferRoot: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-remote-hook-transfers", isDirectory: true)
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "cmux", isDirectory: true)
    }

    private func existingTransferDirectory(for transferID: String) throws -> URL {
        guard let uuid = UUID(uuidString: transferID), uuid.uuidString == transferID.uppercased() else {
            throw bridgeError(
                "invalid_params",
                key: "socket.hooks.remoteBridge.invalidTransfer",
                fallback: "Remote hook payload transfer is missing or too large."
            )
        }
        let directory = transferRoot.appendingPathComponent(uuid.uuidString, isDirectory: true)
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw bridgeError(
                "invalid_params",
                key: "socket.hooks.remoteBridge.invalidTransfer",
                fallback: "Remote hook payload transfer is missing or too large."
            )
        }
        return directory
    }

    private func removeStaleTransfers(now: Date = Date()) {
        let fileManager = FileManager.default
        guard let directories = try? fileManager.contentsOfDirectory(
            at: transferRoot,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for directory in directories {
            guard let modified = try? directory.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate,
                  now.timeIntervalSince(modified) >= staleTransferAge else { continue }
            try? fileManager.removeItem(at: directory)
        }
    }

    private func writePrivate(_ data: Data, to url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path) {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func run(_ invocation: Invocation, localSocketPath: String) throws -> [String: Any] {
        guard let cliURL = Bundle.main.resourceURL?.appendingPathComponent("bin/cmux"),
              FileManager.default.isExecutableFile(atPath: cliURL.path) else {
            throw bridgeError(
                "unavailable",
                key: "socket.hooks.remoteBridge.cliUnavailable",
                fallback: "The bundled cmux CLI is unavailable."
            )
        }
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-hook-invoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let inputURL = temporaryDirectory.appendingPathComponent("stdin")
        let outputURL = temporaryDirectory.appendingPathComponent("stdout")
        let errorURL = temporaryDirectory.appendingPathComponent("stderr")
        try invocation.input.write(to: inputURL)
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        let inputHandle = try FileHandle(forReadingFrom: inputURL)
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        let errorHandle = try FileHandle(forWritingTo: errorURL)
        defer {
            try? inputHandle.close()
            try? outputHandle.close()
            try? errorHandle.close()
        }

        let process = Process()
        process.executableURL = cliURL
        process.arguments = ["--socket", localSocketPath, "hooks"] + invocation.arguments
        process.standardInput = inputHandle
        process.standardOutput = outputHandle
        process.standardError = errorHandle
        process.environment = childEnvironment(
            remote: invocation.environment,
            arguments: invocation.arguments,
            cliPath: cliURL.path,
            socketPath: localSocketPath
        )
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw bridgeError(
                "unavailable",
                key: "socket.hooks.remoteBridge.launchFailed",
                fallback: "The bundled cmux hook command could not be launched."
            )
        }
        try outputHandle.synchronize()
        try errorHandle.synchronize()
        let status = process.terminationReason == .exit
            ? Int(process.terminationStatus)
            : 128 + Int(process.terminationStatus)
        return [
            "stdout_base64": ((try? Data(contentsOf: outputURL)) ?? Data()).base64EncodedString(),
            "stderr_base64": ((try? Data(contentsOf: errorURL)) ?? Data()).base64EncodedString(),
            "exit_code": status,
        ]
    }

    private func childEnvironment(
        remote: [String: String],
        arguments: [String],
        cliPath: String,
        socketPath: String
    ) -> [String: String] {
        var result = ProcessInfo.processInfo.environment
        result["CMUX_SOCKET_PATH"] = socketPath
        result["CMUX_BUNDLED_CLI_PATH"] = cliPath
        result["CMUX_HOOK_RELAY_BACKED"] = "1"
        let pidKeys = result.keys.filter { $0.hasPrefix("CMUX_") && $0.hasSuffix("_PID") }
        for key in pidKeys {
            result.removeValue(forKey: key)
        }
        let isFilesystemBridge = arguments.first?.hasPrefix("__remote-") == true
        let keys = isFilesystemBridge ? Self.filesystemEnvironmentKeys : Self.routingEnvironmentKeys
        for key in keys {
            if let value = remote[key] {
                result[key] = value
            } else {
                result.removeValue(forKey: key)
            }
        }
        if !isFilesystemBridge {
            result["CMUX_BUNDLED_CLI_PATH"] = cliPath
        }
        return result
    }

    private func requiredString(_ key: String, params: [String: Any]) throws -> String {
        guard let value = params[key] as? String, !value.isEmpty, value.utf8.count <= 4_096 else {
            throw bridgeError(
                "invalid_params",
                key: "socket.hooks.remoteBridge.invalidParameters",
                fallback: "Remote hook bridge parameters are invalid."
            )
        }
        return value
    }

    private func decodedData(_ key: String, params: [String: Any]) throws -> Data {
        guard let encoded = params[key] as? String,
              encoded.utf8.count <= maximumInputBytes * 2,
              let data = Data(base64Encoded: encoded) else {
            throw bridgeError(
                "invalid_params",
                key: "socket.hooks.remoteBridge.invalidPayload",
                fallback: "Remote hook payload is invalid."
            )
        }
        return data
    }

    private func bridgeError(_ code: String, key: String, fallback: String) -> BridgeError {
        BridgeError(code: code, message: Bundle.main.localizedString(forKey: key, value: fallback, table: nil))
    }

    private static let routingEnvironmentKeys: Set<String> = [
        "CMUX_WORKSPACE_ID", "CMUX_SURFACE_ID",
        "CMUX_AGENT_LAUNCH_KIND", "CMUX_AGENT_LAUNCH_EXECUTABLE",
        "CMUX_AGENT_LAUNCH_ARGV_B64", "CMUX_AGENT_LAUNCH_CWD",
        "CMUX_REMOTE_PTY_SESSION_ID", "CMUX_SSH_PTY_SESSION_ID", "PWD",
        "CMUX_CLI_TTY_NAME", "CMUX_TTY_NAME", "TTY", "SSH_TTY",
    ]

    private static let filesystemEnvironmentKeys: Set<String> = routingEnvironmentKeys.union([
        "HOME", "CMUX_BUNDLED_CLI_PATH", "CODEX_HOME", "GROK_HOME",
        "OPENCODE_CONFIG_DIR", "PI_CODING_AGENT_DIR", "PI_CONFIG_DIR",
        "CAMPFIRE_CODING_AGENT_DIR", "KIRO_HOME", "HERMES_HOME", "COPILOT_HOME",
        "CODEBUDDY_CONFIG_DIR", "QODER_CONFIG_DIR", "KIMI_SHARE_DIR", "KIMI_CODE_HOME",
    ])
}
