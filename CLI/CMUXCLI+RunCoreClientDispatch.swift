import Foundation
import CMUXAgentLaunch
import CmuxFoundation
import CmuxSocketControl
import CoreFoundation
import CryptoKit
import Darwin
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif
#if canImport(Security)
import Security
#endif
#if canImport(Sentry)
import Sentry
#endif


// MARK: - Core client command dispatch (system, auth, vm, rpc, identify)
extension CMUXCLI {
    /// Handles core system/auth/vm/rpc/identify socket commands.
    /// Returns true when the command matched; false to let the next dispatcher try.
    func runCoreClientCommand(
        command: String,
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        idFormatArg: String?,
        windowId: String?
    ) throws -> Bool {
        switch command {
        case "ping":
            let response = try sendV1Command("ping", client: client)
            print(response)

        case "capabilities":
            let response = try client.sendV2(method: "system.capabilities")
            print(jsonString(formatIDs(response, mode: idFormat)))

        case "agent-hibernation":
            try runAgentHibernation(commandArgs: commandArgs, client: client, jsonOutput: jsonOutput)

        case "auth", "login", "logout":
            let authArgs = command == "auth" ? commandArgs : [command] + commandArgs
            let sub = authArgs.first?.lowercased() ?? "status"
            switch sub {
            case "status":
                let response = try client.sendV2(method: "auth.status")
                if jsonOutput {
                    print(jsonString(response))
                    break
                }
                let signedIn = (response["signed_in"] as? Bool) ?? false
                if !signedIn {
                    print("Not signed in.")
                    print("Run: cmux auth login")
                    break
                }
                let user = response["user"] as? [String: Any]
                let email = user?["email"] as? String
                let display = user?["display_name"] as? String
                let userID = user?["id"] as? String
                print("Signed in.")
                if let email { print("  email:    \(email)") }
                if let display { print("  name:     \(display)") }
                if let userID { print("  user_id:  \(userID)") }
                if let teamID = response["selected_team_id"] as? String {
                    print("  team_id:  \(teamID)")
                }

            case "login":
                let statusBefore = try client.sendV2(method: "auth.status")
                if (statusBefore["signed_in"] as? Bool) == true {
                    let email = (statusBefore["user"] as? [String: Any])?["email"] as? String
                    print("Already signed in\(email.map { " as \($0)" } ?? ""). Use `cmux auth logout` to sign out first.")
                    break
                }
                print("Opening sign-in popup on the cmux web app.")
                // auth.begin_sign_in blocks on the server side until the
                // popup completes (or 5min timeout). The response is the
                // callback — no polling.
                let result = try client.sendV2(method: "auth.begin_sign_in", responseTimeout: 305)
                if (result["signed_in"] as? Bool) == true {
                    let email = (result["user"] as? [String: Any])?["email"] as? String
                    print("Signed in\(email.map { " as \($0)" } ?? "").")
                } else if (result["timed_out"] as? Bool) == true {
                    print("Timed out waiting for sign-in. Run `cmux auth status` once you've finished in the popup.")
                } else {
                    print("Sign-in did not complete. Run `cmux auth status` to check.")
                }

            case "logout":
                let statusBefore = try client.sendV2(method: "auth.status")
                if (statusBefore["signed_in"] as? Bool) != true {
                    print("Already signed out.")
                    break
                }
                // auth.sign_out awaits the token clear before replying.
                let result = try client.sendV2(method: "auth.sign_out")
                if (result["signed_in"] as? Bool) != true {
                    print("Signed out.")
                } else {
                    print("Sign-out requested but state hasn't cleared yet. Run `cmux auth status` to confirm.")
                }

            default:
                throw CLIError(message: "Usage: cmux auth <status|login|logout>")
            }

        case "vm", "cloud":
            let sub = commandArgs.first?.lowercased() ?? "ls"
            let rest = Array(commandArgs.dropFirst())
            switch sub {
            case "ls", "list":
                let response = try client.sendV2(method: "vm.list")
                if jsonOutput {
                    print(jsonString(response))
                    break
                }
                let vms = (response["vms"] as? [[String: Any]]) ?? []
                if vms.isEmpty {
                    print("No cloud VMs. Try: cmux vm new")
                    break
                }
                for vm in vms {
                    let id = (vm["id"] as? String) ?? "?"
                    let provider = (vm["provider"] as? String) ?? "?"
                    let image = (vm["image"] as? String) ?? "?"
                    print("\(id)  [\(provider)] \(image)")
                }

            case "new", "create":
                let (imageOpt, rem0) = parseOption(rest, name: "--image")
                let (providerOpt, rem1) = parseOption(rem0, name: "--provider")
                let (windowOpt, rem2) = parseOption(rem1, name: "--window")
                let detach = hasFlag(rem2, name: "--detach") || hasFlag(rem2, name: "-d")
                let remaining = rem2.filter { $0 != "--detach" && $0 != "-d" }
                if let unknown = remaining.first(where: { Self.isUnknownFlagToken($0, allowedShortFlags: ["-d"]) }) {
                    throw CLIError(message: """
                        vm new: unknown flag '\(unknown)'.

                        Known flags:
                          --image <image-id>
                          --provider <provider>
                          --detach, -d

                        Try:
                          cmux vm new
                        """)
                }
                // Stray positional args (e.g. a typo like `cmux vm new myvm`) previously fell
                // through and still provisioned a VM. That silently costs the user money and
                // hides the typo. Reject them explicitly.
                if let extra = remaining.first(where: { !Self.isFlagToken($0) }) {
                    throw CLIError(
                        message: """
                            vm new: unexpected argument '\(extra)'.

                            `cmux vm new` does not take a VM name or positional arguments.

                            Try:
                              cmux vm new
                              cmux vm new --detach
                            """
                    )
                }
                let normalizedProvider = try Self.normalizedVMProvider(providerOpt)
                var params: [String: Any] = [:]
                if let imageOpt { params["image"] = imageOpt }
                if let normalizedProvider { params["provider"] = normalizedProvider }
                let targetWindow = try validatedWindowHandle(windowOpt ?? windowId, client: client)
                let idempotency = try Self.activeVMCreateIdempotency(image: imageOpt, provider: normalizedProvider)
                params["idempotency_key"] = idempotency.key
                let vmCreateStartedAt = Date()
                let response = try client.sendV2(
                    method: "vm.create",
                    params: params,
                    responseTimeout: Self.vmCreateResponseTimeoutSeconds
                )
                logVMTiming(
                    "create",
                    vmID: (response["id"] as? String) ?? "?",
                    provider: (response["provider"] as? String) ?? normalizedProvider ?? "?",
                    startedAt: vmCreateStartedAt
                )
                if jsonOutput {
                    Self.clearVMCreateIdempotency(idempotency)
                    print(jsonString(response))
                    break
                }
                let id = (response["id"] as? String) ?? "?"
                let provider = (response["provider"] as? String) ?? "?"
                let image = (response["image"] as? String) ?? "?"
                if detach {
                    Self.clearVMCreateIdempotency(idempotency)
                    print("OK \(id)")
                    print("  provider: \(provider)")
                    print("  image:    \(image)")
                    break
                }
                // Create the VM then drop the user into a cmux-managed workspace. Freestyle
                // attaches over SSH; E2B attaches over cmuxd-remote WebSocket PTY.
                let shortId = String(id.prefix(8))
                print("Created \(id)  [\(provider)]  \(image)")
                try vmOpenShell(
                    id: id,
                    workspaceName: "vm:\(shortId)",
                    windowRaw: targetWindow,
                    client: client,
                    jsonOutput: jsonOutput,
                    idFormat: idFormat
                )
                Self.clearVMCreateIdempotency(idempotency)

            case "shell", "attach":
                let (windowOpt, vmArgs) = parseOption(rest, name: "--window")
                guard let vmId = vmArgs.first else {
                    throw CLIError(message: """
                        Usage: cmux \(command) shell <id>

                        Find an id:
                          cmux vm ls
                        """)
                }
                let shortId = String(vmId.prefix(8))
                try vmOpenShell(
                    id: vmId,
                    workspaceName: "vm:\(shortId)",
                    windowRaw: windowOpt ?? windowId,
                    client: client,
                    jsonOutput: jsonOutput,
                    idFormat: idFormat
                )

            case "rm", "destroy", "delete":
                guard let vmId = rest.first else {
                    throw CLIError(message: """
                        Usage: cmux vm rm <id>

                        Find an id:
                          cmux vm ls
                        """)
                }
                _ = try client.sendV2(method: "vm.destroy", params: ["id": vmId], responseTimeout: 60)
                if jsonOutput {
                    print("{\"ok\":true,\"id\":\"\(vmId)\"}")
                } else {
                    print("OK \(vmId)")
                }

            case "ssh":
                let (windowOpt, vmArgs) = parseOption(rest, name: "--window")
                guard let vmId = vmArgs.first else {
                    throw CLIError(message: """
                        Usage: cmux \(command) ssh <id>

                        Find an id:
                          cmux vm ls
                        """)
                }
                let shortId = String(vmId.prefix(8))
                try vmOpenShell(
                    id: vmId,
                    workspaceName: "vm:\(shortId)",
                    windowRaw: windowOpt ?? windowId,
                    client: client,
                    jsonOutput: jsonOutput,
                    idFormat: idFormat
                )

            case "ssh-info":
                guard let vmId = rest.first else {
                    throw CLIError(message: """
                        Usage: cmux \(command) ssh-info <id>

                        Find an id:
                          cmux vm ls
                        """)
                }
                try printVMSSHInfo(id: vmId, command: command, client: client, jsonOutput: jsonOutput)

            case "ssh-attach":
                try runVMSSHAttach(commandArgs: rest, client: client)

            case "exec":
                guard let vmId = rest.first else {
                    throw CLIError(message: """
                        Usage: cmux vm exec <id> -- <command...>

                        Examples:
                          cmux vm ls
                          cmux vm exec <id> -- pwd
                        """)
                }
                var commandArgsForVM: [String] = Array(rest.dropFirst())
                // Consume a leading "--" separator if present.
                if commandArgsForVM.first == "--" {
                    commandArgsForVM.removeFirst()
                }
                guard !commandArgsForVM.isEmpty else {
                    throw CLIError(message: """
                        Usage: cmux vm exec <id> -- <command...>

                        Example:
                          cmux vm exec \(vmId) -- uname -a
                        """)
                }
                // Shell-quote each argv element before joining. Plain-space join previously
                // dropped quoting so `cmux vm exec <id> -- printf '%s\n' "a b"` reached the
                // VM as `printf %s\n a b`, changing semantics for any non-trivial command
                // (Codex P2).
                let command = commandArgsForVM.map(shellQuote).joined(separator: " ")
                let response = try client.sendV2(
                    method: "vm.exec",
                    params: ["id": vmId, "command": command],
                    responseTimeout: 35
                )
                let stdout = (response["stdout"] as? String) ?? ""
                let stderr = (response["stderr"] as? String) ?? ""
                let exitCode = (response["exit_code"] as? Int) ?? -1
                if jsonOutput {
                    print(jsonString(response))
                    if exitCode != 0 {
                        throw CLIError(message: "exit \(exitCode)")
                    }
                    break
                }
                if !stdout.isEmpty { print(stdout, terminator: stdout.hasSuffix("\n") ? "" : "\n") }
                if !stderr.isEmpty {
                    FileHandle.standardError.write(Data(stderr.utf8))
                    if !stderr.hasSuffix("\n") {
                        FileHandle.standardError.write(Data("\n".utf8))
                    }
                }
                if exitCode != 0 {
                    throw CLIError(message: "exit \(exitCode)")
                }

            default:
                throw CLIError(message: """
                    Usage: cmux \(command) <ls|new|shell|rm|exec|ssh> [args...]

                    Common commands:
                      cmux vm ls
                      cmux vm new
                      cmux vm ssh <id>
                      cmux vm rm <id>
                    """)
            }

        case "rpc":
            guard let method = commandArgs.first?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !method.isEmpty else {
                throw CLIError(message: "Usage: cmux rpc <method> [json-params]")
            }
            let params = try parseRPCParams(Array(commandArgs.dropFirst()))
            let response = try client.sendV2(method: method, params: params)
            let output: Any = idFormatArg == nil ? response : formatIDs(response, mode: idFormat)
            print(jsonString(output))

        case "identify":
            var params: [String: Any] = [:]
            let localWindowRaw = optionValue(commandArgs, name: "--window")
            let effectiveWindowRaw = localWindowRaw ?? windowId
            let targetWindow = try normalizeWindowHandle(effectiveWindowRaw, client: client)
            if let targetWindow {
                params["window_id"] = targetWindow
            }
            let includeCaller = !hasFlag(commandArgs, name: "--no-caller")
            if includeCaller {
                let idWsFlag = optionValue(commandArgs, name: "--workspace")
                let workspaceArg = idWsFlag ?? (effectiveWindowRaw == nil ? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] : nil)
                let surfaceArg = optionValue(commandArgs, name: "--surface") ?? (idWsFlag == nil && effectiveWindowRaw == nil ? ProcessInfo.processInfo.environment["CMUX_SURFACE_ID"] : nil)
                if workspaceArg != nil || surfaceArg != nil {
                    let workspaceId = try normalizeWorkspaceHandle(
                        workspaceArg,
                        client: client,
                        windowHandle: targetWindow,
                        allowCurrent: surfaceArg != nil
                    )
                    var caller: [String: Any] = [:]
                    if let workspaceId {
                        caller["workspace_id"] = workspaceId
                    }
                    if surfaceArg != nil {
                        guard let surfaceId = try normalizeSurfaceHandle(
                            surfaceArg,
                            client: client,
                            workspaceHandle: workspaceId,
                            windowHandle: targetWindow
                        ) else {
                            throw CLIError(message: "Invalid surface handle")
                        }
                        caller["surface_id"] = surfaceId
                    }
                    if !caller.isEmpty {
                        params["caller"] = caller
                    }
                }
            }
            let response = try client.sendV2(method: "system.identify", params: params)
            print(jsonString(formatIDs(response, mode: idFormat)))
        default:
            return false
        }
        return true
    }

    private func parseRPCParams(_ args: [String]) throws -> [String: Any] {
        guard !args.isEmpty else { return [:] }
        let raw = args.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return [:] }
        guard let data = raw.data(using: .utf8) else {
            throw CLIError(message: "rpc params must be valid UTF-8 JSON")
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw CLIError(message: "rpc params must be valid JSON: \(error.localizedDescription)")
        }
        guard let params = object as? [String: Any] else {
            throw CLIError(message: "rpc params must be a JSON object")
        }
        return params
    }

}
