import Foundation
import CMUXMobileCore

extension CMUXCLI {
    private struct RemoteMacOpenOptions {
        let destination: String
        let sshPort: Int?
        let identityFile: String?
        let workspaceName: String?
        let windowRaw: String?
        let remoteWindowRaw: String?
        let createNewWindow: Bool
        let noFocus: Bool
        let sshOptions: [String]
        let localPort: Int
        let ttlSeconds: Int
        let remoteCMUXPath: String
        let remoteSocketPath: String?
        let routeKind: CmxAttachTransportKind
    }

    private struct RemoteMacTicketMint {
        let rawResponse: [String: Any]
        let ticket: CmxAttachTicket
    }

    private struct RemoteMacWindowScope {
        let id: String
        let ref: String?
    }

    func runRemoteNamespace(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowOverride: String?
    ) throws {
        guard let subcommand = commandArgs.first?.lowercased() else {
            throw CLIError(message: "Usage: cmux remote mac open <user@mac>")
        }
        switch subcommand {
        case "mac":
            try runRemoteMac(commandArgs: Array(commandArgs.dropFirst()), client: client, jsonOutput: jsonOutput, idFormat: idFormat, windowOverride: windowOverride)
        default:
            throw CLIError(message: "Unknown remote subcommand '\(subcommand)'. Try: cmux remote mac open <user@mac>")
        }
    }

    private func runRemoteMac(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowOverride: String?
    ) throws {
        let action = commandArgs.first?.lowercased() ?? "open"
        let rest = action == "open" ? Array(commandArgs.dropFirst()) : commandArgs
        guard action == "open" else {
            throw CLIError(message: "Usage: cmux remote mac open <user@mac>")
        }
        let options = try parseRemoteMacOpenOptions(rest, windowOverride: windowOverride)
        let remoteWindow = try resolveRemoteMacWindowScope(options)
        let mint = try mintRemoteMacAttachTicket(options)
        let tunneled = try CmxSSHTunneledAttachTicket(
            ticket: mint.ticket,
            localPort: options.localPort,
            supportedRemoteKinds: [options.routeKind]
        )
        guard case let .hostPort(remoteHost, remotePort) = tunneled.remoteRoute.endpoint else {
            throw CLIError(message: "Remote Mac attach route is not a host/port route.")
        }

        var sshOptions = remoteMacSSHOptionsWithNetworkDefaults(options.sshOptions)
        if !hasSSHOptionKey(sshOptions, key: "ExitOnForwardFailure") {
            sshOptions.append("ExitOnForwardFailure=yes")
        }
        let localEndpoint = remoteMacSSHForwardEndpoint(host: "127.0.0.1", port: options.localPort)
        let forwardTarget = remoteMacSSHForwardEndpoint(host: remoteHost, port: remotePort)
        sshOptions.append("LocalForward=\(localEndpoint) \(forwardTarget)")

        let workspaceName = options.workspaceName ?? "cmux:\(options.destination)"
        let attachURL = try tunneled.attachURL().absoluteString
        let targetWindowRaw = try remoteMacTargetWindowRaw(options: options, client: client)
        let createdWindowRaw = options.createNewWindow ? targetWindowRaw : nil
        let sshCommandOptions = SSHCommandOptions(
            destination: options.destination,
            port: options.sshPort,
            identityFile: options.identityFile,
            workspaceName: workspaceName,
            windowRaw: targetWindowRaw,
            noFocus: options.noFocus,
            sshOptions: sshOptions,
            extraArguments: [],
            localSocketPath: client.socketPath,
            remoteRelayPort: 0,
            skipDaemonBootstrap: true
        )
        let relayID = UUID().uuidString.lowercased()
        let relayToken = try randomHex(byteCount: 32)
        do {
            _ = try runSSHWithOptions(
                sshCommandOptions,
                relayID: relayID,
                relayToken: relayToken,
                client: client,
                jsonOutput: jsonOutput,
                idFormat: idFormat,
                decorateConfigureParams: { params in
                    params["remote_mac_local_endpoint"] = localEndpoint
                    params["remote_mac_forward_target"] = forwardTarget
                    params["remote_mac_window_id"] = remoteWindow.id
                }
            ) { payload in
                payload["remote_mac_attach_url"] = attachURL
                payload["remote_mac_local_endpoint"] = localEndpoint
                payload["remote_mac_forward_target"] = forwardTarget
                payload["remote_mac_window_id"] = remoteWindow.id
                if let remoteWindowRef = remoteWindow.ref {
                    payload["remote_mac_window_ref"] = remoteWindowRef
                }
                payload["remote_mac_ticket"] = mint.rawResponse["ticket"]
            }
        } catch {
            closeRemoteMacCreatedWindowIfNeeded(createdWindowRaw, client: client)
            throw error
        }
        if !jsonOutput {
            print("remote_window_id=\(remoteWindow.id)")
            print("attach_url=\(attachURL)")
            print("tunnel=\(localEndpoint) -> \(forwardTarget)")
        }
    }

    private func parseRemoteMacOpenOptions(
        _ commandArgs: [String],
        windowOverride: String?
    ) throws -> RemoteMacOpenOptions {
        var destination: String?
        var sshPort: Int?
        var identityFile: String?
        var workspaceName: String?
        var windowRaw: String?
        var remoteWindowRaw: String?
        var createNewWindow = false
        var noFocus = false
        var sshOptions: [String] = []
        var localPort: Int?
        var ttlSeconds = 600
        var remoteCMUXPath = "cmux"
        var remoteSocketPath: String?
        var routeKind = CmxAttachTransportKind.tailscale

        var index = 0
        while index < commandArgs.count {
            let arg = commandArgs[index]
            switch arg {
            case "--port":
                guard index + 1 < commandArgs.count else {
                    throw CLIError(message: "remote mac open: --port requires a value")
                }
                sshPort = try parseTCPPort(commandArgs[index + 1], flag: "--port")
                index += 2
            case "--identity":
                guard index + 1 < commandArgs.count else {
                    throw CLIError(message: "remote mac open: --identity requires a path")
                }
                identityFile = commandArgs[index + 1]
                index += 2
            case "--name":
                guard index + 1 < commandArgs.count else {
                    throw CLIError(message: "remote mac open: --name requires a workspace title")
                }
                workspaceName = commandArgs[index + 1]
                index += 2
            case "--window":
                guard index + 1 < commandArgs.count else {
                    throw CLIError(message: "remote mac open: --window requires a window id")
                }
                windowRaw = commandArgs[index + 1]
                index += 2
            case "--remote-window":
                guard index + 1 < commandArgs.count else {
                    throw CLIError(message: "remote mac open: --remote-window requires a remote window id, ref, index, or current")
                }
                remoteWindowRaw = commandArgs[index + 1]
                index += 2
            case "--new-window":
                createNewWindow = true
                index += 1
            case "--no-focus":
                noFocus = true
                index += 1
            case "--ssh-option":
                guard index + 1 < commandArgs.count else {
                    throw CLIError(message: "remote mac open: --ssh-option requires a value")
                }
                let value = commandArgs[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty {
                    sshOptions.append(value)
                }
                index += 2
            case "--local-port":
                guard index + 1 < commandArgs.count else {
                    throw CLIError(message: "remote mac open: --local-port requires a value")
                }
                localPort = try parseTCPPort(commandArgs[index + 1], flag: "--local-port")
                index += 2
            case "--ttl":
                guard index + 1 < commandArgs.count else {
                    throw CLIError(message: "remote mac open: --ttl requires seconds")
                }
                guard let parsed = Int(commandArgs[index + 1]), (30...3600).contains(parsed) else {
                    throw CLIError(message: "remote mac open: --ttl must be 30-3600 seconds")
                }
                ttlSeconds = parsed
                index += 2
            case "--remote-cmux":
                guard index + 1 < commandArgs.count else {
                    throw CLIError(message: "remote mac open: --remote-cmux requires a path")
                }
                let value = commandArgs[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else {
                    throw CLIError(message: "remote mac open: --remote-cmux cannot be empty")
                }
                remoteCMUXPath = value
                index += 2
            case "--remote-socket":
                guard index + 1 < commandArgs.count else {
                    throw CLIError(message: "remote mac open: --remote-socket requires a path")
                }
                let value = commandArgs[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else {
                    throw CLIError(message: "remote mac open: --remote-socket cannot be empty")
                }
                remoteSocketPath = value
                index += 2
            case "--route-kind":
                guard index + 1 < commandArgs.count else {
                    throw CLIError(message: "remote mac open: --route-kind requires a value")
                }
                guard let parsed = CmxAttachTransportKind(rawValue: commandArgs[index + 1]) else {
                    throw CLIError(message: "remote mac open: --route-kind must be tailscale")
                }
                routeKind = parsed
                index += 2
            default:
                if arg.hasPrefix("--") {
                    throw CLIError(message: "remote mac open: unknown flag '\(arg)'")
                }
                guard destination == nil else {
                    throw CLIError(message: "remote mac open: unexpected argument '\(arg)'")
                }
                destination = arg
                index += 1
            }
        }

        guard routeKind == .tailscale else {
            throw CLIError(message: "remote mac open: only --route-kind tailscale can be SSH-forwarded today")
        }
        guard let destination, !destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CLIError(message: "Usage: cmux remote mac open <user@mac>")
        }
        if destination.hasPrefix("-") {
            throw CLIError(message: "remote mac open: destination must be <user@host>")
        }
        if createNewWindow && (windowRaw != nil || windowOverride != nil) {
            throw CLIError(message: "remote mac open: --new-window cannot be combined with --window")
        }

        return RemoteMacOpenOptions(
            destination: destination,
            sshPort: sshPort,
            identityFile: identityFile,
            workspaceName: workspaceName,
            windowRaw: windowRaw ?? windowOverride,
            remoteWindowRaw: remoteWindowRaw,
            createNewWindow: createNewWindow,
            noFocus: noFocus,
            sshOptions: sshOptions,
            localPort: localPort ?? generateRemoteRelayPort(),
            ttlSeconds: ttlSeconds,
            remoteCMUXPath: remoteCMUXPath,
            remoteSocketPath: remoteSocketPath,
            routeKind: routeKind
        )
    }

    private func remoteMacTargetWindowRaw(options: RemoteMacOpenOptions, client: SocketClient) throws -> String? {
        guard options.createNewWindow else {
            return options.windowRaw
        }
        let response = try sendV1Command("new_window", client: client)
        let windowID = parseNewWindowID(response)
        guard !windowID.isEmpty else {
            throw CLIError(message: "remote mac open: new_window did not return a window id")
        }
        return windowID
    }

    private func closeRemoteMacCreatedWindowIfNeeded(_ windowRaw: String?, client: SocketClient) {
        guard let windowRaw = windowRaw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !windowRaw.isEmpty else {
            return
        }
        _ = try? sendV1Command("close_window \(windowRaw)", client: client)
    }

    private func remoteMacSSHForwardEndpoint(host: String, port: Int) -> String {
        if host.contains(":") && !(host.hasPrefix("[") && host.hasSuffix("]")) {
            return "[\(host)]:\(port)"
        }
        return "\(host):\(port)"
    }

    private func parseNewWindowID(_ response: String) -> String {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("OK ") {
            return String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    private func resolveRemoteMacWindowScope(_ options: RemoteMacOpenOptions) throws -> RemoteMacWindowScope {
        let requested = options.remoteWindowRaw?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedOrCurrent = (requested?.isEmpty == false) ? requested! : "current"
        let lowered = requestedOrCurrent.lowercased()
        if lowered == "current" || lowered == "selected" {
            let response = try runRemoteMacCMUXRPC(
                options: options,
                method: "window.current",
                params: [:]
            )
            guard let id = normalizedRemoteMacWindowID(response["window_id"] as? String) else {
                throw CLIError(message: "remote mac open: remote cmux did not report the current window id")
            }
            return RemoteMacWindowScope(id: id, ref: response["window_ref"] as? String)
        }
        if let id = normalizedRemoteMacWindowID(requestedOrCurrent) {
            return RemoteMacWindowScope(id: id, ref: nil)
        }

        let response = try runRemoteMacCMUXRPC(
            options: options,
            method: "window.list",
            params: [:]
        )
        guard let windows = response["windows"] as? [[String: Any]] else {
            throw CLIError(message: "remote mac open: remote cmux did not report a window list")
        }
        let matched = windows.first { window in
            if let id = window["id"] as? String, id.caseInsensitiveCompare(requestedOrCurrent) == .orderedSame {
                return true
            }
            if let ref = window["ref"] as? String, ref.caseInsensitiveCompare(requestedOrCurrent) == .orderedSame {
                return true
            }
            if let index = intFromAny(window["index"]), requestedOrCurrent == String(index) {
                return true
            }
            return false
        }
        guard let matched,
              let id = normalizedRemoteMacWindowID(matched["id"] as? String) else {
            throw CLIError(message: "remote mac open: remote window not found: \(requestedOrCurrent)")
        }
        return RemoteMacWindowScope(id: id, ref: matched["ref"] as? String)
    }

    private func normalizedRemoteMacWindowID(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              let uuid = UUID(uuidString: raw) else {
            return nil
        }
        return uuid.uuidString
    }

    private func parseTCPPort(_ raw: String, flag: String) throws -> Int {
        guard let port = Int(raw), (1...65_535).contains(port) else {
            throw CLIError(message: "remote mac open: \(flag) must be 1-65535")
        }
        return port
    }

    private func mintRemoteMacAttachTicket(_ options: RemoteMacOpenOptions) throws -> RemoteMacTicketMint {
        _ = try? runRemoteMacCMUXRPC(
            options: options,
            method: "mobile.host.ensure",
            params: [:]
        )
        let params: [String: Any] = [
            "scope": "mac",
            "route_kind": options.routeKind.rawValue,
            "ttl_seconds": options.ttlSeconds,
        ]
        let response = try runRemoteMacCMUXRPC(
            options: options,
            method: "mobile.attach_ticket.create",
            params: params
        )
        guard let ticketObject = response["ticket"] else {
            throw CLIError(message: "remote mac open: remote cmux did not return an attach ticket. Make sure iOS pairing is enabled on the remote Mac.")
        }
        let ticketData = try JSONSerialization.data(withJSONObject: ticketObject, options: [])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let ticket = try decoder.decode(CmxAttachTicket.self, from: ticketData)
        return RemoteMacTicketMint(rawResponse: response, ticket: ticket)
    }

    private func runRemoteMacCMUXRPC(
        options: RemoteMacOpenOptions,
        method: String,
        params: [String: Any]
    ) throws -> [String: Any] {
        let paramsData = try JSONSerialization.data(withJSONObject: params, options: [.sortedKeys])
        guard let paramsJSON = String(data: paramsData, encoding: .utf8) else {
            throw CLIError(message: "remote mac open: failed to encode \(method) params")
        }
        var remoteScriptParts: [String] = []
        if let remoteSocketPath = options.remoteSocketPath {
            remoteScriptParts.append("CMUX_SOCKET=\(shellQuote(remoteSocketPath))")
            remoteScriptParts.append("CMUX_SOCKET_PATH=\(shellQuote(remoteSocketPath))")
        }
        remoteScriptParts += [
            shellQuote(options.remoteCMUXPath),
            "--json",
            "rpc",
            shellQuote(method),
            shellQuote(paramsJSON),
        ]
        let remoteScript = remoteScriptParts.joined(separator: " ")
        let rpcSSHOptions = SSHCommandOptions(
            destination: options.destination,
            port: options.sshPort,
            identityFile: options.identityFile,
            workspaceName: nil,
            windowRaw: nil,
            noFocus: true,
            sshOptions: remoteMacSSHOptionsForPreflight(options.sshOptions),
            extraArguments: [posixShellCommand(remoteScript)],
            localSocketPath: "",
            remoteRelayPort: 0,
            skipDaemonBootstrap: true
        )
        let output = try runRemoteMacSSHCommand(arguments: buildSSHCommandArguments(rpcSSHOptions))
        return try decodeRemoteMacJSONObject(output)
    }

    private func remoteMacSSHOptionsWithNetworkDefaults(_ options: [String]) -> [String] {
        var merged = options
        if !hasSSHOptionKey(merged, key: "ConnectionAttempts") {
            merged.append("ConnectionAttempts=3")
        }
        if !hasSSHOptionKey(merged, key: "ServerAliveInterval") {
            merged.append("ServerAliveInterval=10")
        }
        if !hasSSHOptionKey(merged, key: "ServerAliveCountMax") {
            merged.append("ServerAliveCountMax=3")
        }
        return merged
    }

    private func remoteMacSSHOptionsForPreflight(_ options: [String]) -> [String] {
        var merged = remoteMacSSHOptionsWithNetworkDefaults(options)
        if !hasSSHOptionKey(merged, key: "BatchMode") {
            merged.append("BatchMode=yes")
        }
        if !hasSSHOptionKey(merged, key: "NumberOfPasswordPrompts") {
            merged.append("NumberOfPasswordPrompts=0")
        }
        if !hasSSHOptionKey(merged, key: "StrictHostKeyChecking") {
            merged.append("StrictHostKeyChecking=accept-new")
        }
        return merged
    }

    private func runRemoteMacSSHCommand(arguments: [String]) throws -> String {
        guard let launchPath = arguments.first else {
            throw CLIError(message: "remote mac open: could not construct ssh command")
        }
        let result: CLIProcessResult
        if launchPath.contains("/") {
            result = CLIProcessRunner.runProcess(
                executablePath: launchPath,
                arguments: Array(arguments.dropFirst()),
                timeout: 30
            )
        } else {
            result = CLIProcessRunner.runProcess(
                executablePath: "/usr/bin/env",
                arguments: arguments,
                timeout: 30
            )
        }
        if result.timedOut {
            throw CLIError(message: "remote mac open: ssh preflight timed out after 30 seconds")
        }
        guard result.status == 0 else {
            let details = compactRemoteMacSSHError(stderr: result.stderr, stdout: result.stdout)
            throw CLIError(message: "remote mac open: ssh exited with status \(result.status)\(details)")
        }
        return result.stdout
    }

    private func compactRemoteMacSSHError(stderr: String, stdout: String) -> String {
        let combined = [stderr, stdout]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        guard !combined.isEmpty else {
            return ""
        }
        let maxLength = 600
        let clipped = combined.count > maxLength ? String(combined.prefix(maxLength)) + "..." : combined
        return ": \(clipped)"
    }

    private func decodeRemoteMacJSONObject(_ output: String) throws -> [String: Any] {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = trimmed.firstIndex(of: "{"),
              let end = trimmed.lastIndex(of: "}"),
              start <= end else {
            throw CLIError(message: "remote mac open: remote cmux did not print JSON")
        }
        let jsonText = String(trimmed[start...end])
        guard let data = jsonText.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CLIError(message: "remote mac open: remote cmux printed invalid JSON")
        }
        return object
    }
}
