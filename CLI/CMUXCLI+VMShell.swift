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


// MARK: - VM shell and VM SSH attach
extension CMUXCLI {
    /// Open an interactive cmux-managed shell on a cloud VM. Freestyle uses the existing SSH
    /// workspace path. E2B uses the cmuxd-remote WebSocket PTY path because E2B does not expose
    /// raw TCP/22.
    func logVMTiming(
        _ stage: String,
        vmID: String,
        provider: String? = nil,
        transport: String? = nil,
        startedAt: Date,
        extra: String = ""
    ) {
        let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        var parts = [
            "cli.vm.timing",
            "vm=\(String(vmID.prefix(8)))",
            "stage=\(stage)",
            "elapsedMs=\(elapsedMs)",
        ]
        if let provider, !provider.isEmpty {
            parts.append("provider=\(provider)")
        }
        if let transport, !transport.isEmpty {
            parts.append("transport=\(transport)")
        }
        if !extra.isEmpty {
            parts.append(extra)
        }
        cliDebugLog(parts.joined(separator: " "))
    }

    func vmOpenShell(
        id: String,
        workspaceName: String?,
        windowRaw: String?,
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        let attachInfoStartedAt = Date()
        let response = try client.sendV2(
            method: "vm.attach_info",
            params: ["id": id, "require_daemon": true],
            responseTimeout: Self.vmAttachResponseTimeoutSeconds
        )
        let transport = (response["transport"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? "ssh"
        logVMTiming("attach_info", vmID: id, transport: transport, startedAt: attachInfoStartedAt)
        if transport == "websocket" {
            let endpoint = try parseVMPtyWebSocketEndpoint(response)
            guard endpoint.daemon != nil else {
                throw CLIError(
                    message: """
                        This Cloud VM image does not support interactive attach in this cmux build.

                        What to do:
                          Update cmux, then create a fresh VM with `cmux vm new`.
                          If this keeps happening, contact support with the VM id.

                        Details:
                          Interactive attach is not available for this VM image.
                        """
                )
            }
            try runVMPtyWebSocketWorkspace(
                id: id,
                endpoint: endpoint,
                workspaceName: workspaceName,
                windowRaw: windowRaw,
                client: client,
                jsonOutput: jsonOutput,
                idFormat: idFormat
            )
            return
        }
        let options = try vmSSHOptions(
            fromAttachInfo: response,
            workspaceName: workspaceName,
            windowRaw: windowRaw,
            client: client,
            remoteRelayPort: generateRemoteRelayPort()
        )
        let relayID = UUID().uuidString.lowercased()
        let relayToken = try randomHex(byteCount: 32)
        try runSSHWithOptions(
            options,
            relayID: relayID,
            relayToken: relayToken,
            client: client,
            jsonOutput: jsonOutput,
            idFormat: idFormat,
            vmIDForSplitAttach: id
        )
    }

    private func vmSSHOptions(
        fromAttachInfo response: [String: Any],
        workspaceName: String?,
        windowRaw: String?,
        client: SocketClient,
        remoteRelayPort: Int
    ) throws -> SSHCommandOptions {
        guard (response["transport"] as? String) == "ssh",
              let host = response["host"] as? String,
              let port = response["port"] as? Int,
              let username = response["username"] as? String,
              let cred = response["credential"] as? [String: Any],
              let kind = cred["kind"] as? String
        else {
            throw CLIError(message: """
                cmux could not read the attach information for this Cloud VM.

                What to do:
                  Retry `cmux vm ssh <id>`.
                  If it keeps failing, recreate the VM with `cmux vm new` and share the details below.

                Details:
                  Cloud VM attach details were incomplete.
                """)
        }
        guard kind == "password" else {
            if kind == "authorizedKey" {
                throw CLIError(
                    message: """
                        This Cloud VM does not support interactive SSH attach in this cmux build.

                        What to do:
                          Update cmux and retry.
                          If this keeps happening, contact support with the VM id.

                        Details:
                          Interactive SSH attach is unavailable for this VM.
                        """
                )
            }
            throw CLIError(message: """
                cmux could not use the attach information for this Cloud VM.

                What to do:
                  Retry `cmux vm ssh <id>`.
                  If it keeps failing, recreate the VM with `cmux vm new`.

                Details:
                  Interactive SSH attach is unavailable for this VM.
                """)
        }
        guard let token = cred["value"] as? String,
              !token.isEmpty else {
            throw CLIError(message: """
                cmux could not open an interactive SSH session for this Cloud VM.

                What to do:
                  Retry `cmux vm ssh <id>`.
                  If it keeps failing, recreate the VM with `cmux vm new`.

                Details:
                  Cloud VM attach details were incomplete.
                """)
        }

        // Freestyle gateway has a fresh host key per session and we re-mint per attach,
        // so skip the StrictHostKeyChecking prompt and known_hosts caching.
        //
        // IdentitiesOnly=yes + IdentityFile=/dev/null is load-bearing: the gateway
        // authenticates via the SSH "none" method with the token embedded in the username.
        // If OpenSSH offers local pubkeys first, the gateway rejects before "none" can run.
        //
        // Each VM pane needs an independent gateway session. Reusing OpenSSH control sockets
        // can make a new split disturb the original shell.
        let sshOptionStrings = [
            "StrictHostKeyChecking=no",
            "UserKnownHostsFile=/dev/null",
            "LogLevel=ERROR",
            "IdentitiesOnly=yes",
            "IdentityFile=/dev/null",
            "PreferredAuthentications=none,password",
            "ControlMaster=no",
        ]
        return SSHCommandOptions(
            destination: "\(username):\(token)@\(host)",
            displayDestination: "\(username)@\(host)",
            port: port,
            identityFile: nil,
            workspaceName: workspaceName,
            windowRaw: windowRaw,
            noFocus: false,
            sshOptions: sshOptionStrings,
            extraArguments: [],
            localSocketPath: client.socketPath,
            remoteRelayPort: remoteRelayPort,
            skipDaemonBootstrap: true
        )
    }

    func printVMSSHInfo(id vmID: String, command: String, client: SocketClient, jsonOutput: Bool) throws {
        let response = try client.sendV2(method: "vm.ssh_info", params: ["id": vmID], responseTimeout: 60)
        if jsonOutput {
            print(jsonString(response))
            return
        }
        let host = (response["host"] as? String) ?? "?"
        let port = (response["port"] as? Int) ?? 22
        let username = (response["username"] as? String) ?? "?"
        let cred = (response["credential"] as? [String: Any]) ?? [:]
        let credKind = (cred["kind"] as? String) ?? "?"
        let credValue = (cred["value"] as? String) ?? "?"
        if credKind == "password" {
            print("ssh \(username)@\(host) -p \(port)")
            print("")
            print("  host:      \(host)")
            print("  port:      \(port)")
            print("  username:  \(username)")
            print("  password:  \(credValue)")
        } else {
            print("This Cloud VM does not support `cmux \(command) ssh-info` in this cmux build.")
            print("")
            print("What to do:")
            print("  Update cmux and retry.")
            print("  If this keeps happening, contact support with the VM id.")
        }
    }

    func runVMSSHAttach(commandArgs: [String], client: SocketClient) throws {
        let (vmIDOpt, remaining) = parseOption(commandArgs, name: "--id")
        if let unknown = remaining.first(where: { Self.isFlagToken($0) }) {
            throw CLIError(message: "vm ssh-attach: unknown flag '\(unknown)'. Use `cmux vm ssh-attach --id <vm-id>`.")
        }
        guard remaining.isEmpty else {
            throw CLIError(message: "Usage: cmux vm ssh-attach --id <vm-id>")
        }
        guard let vmID = vmIDOpt?.trimmingCharacters(in: .whitespacesAndNewlines),
              !vmID.isEmpty else {
            throw CLIError(message: "Usage: cmux vm ssh-attach --id <vm-id>")
        }

        let attachInfoStartedAt = Date()
        let response = try client.sendV2(method: "vm.attach_info", params: ["id": vmID], responseTimeout: Self.vmAttachResponseTimeoutSeconds)
        logVMTiming("attach_info", vmID: vmID, transport: "ssh", startedAt: attachInfoStartedAt)
        let options = try vmSSHOptions(
            fromAttachInfo: response,
            workspaceName: nil,
            windowRaw: nil,
            client: client,
            remoteRelayPort: 0
        )
        let sshArguments = buildSSHCommandArguments(options)
        guard let launchPath = sshArguments.first else {
            throw CLIError(message: "vm ssh-attach could not construct an ssh command. Retry `cmux vm ssh <id>` from a normal cmux shell.")
        }
        client.close()
        try execInteractiveProgram(
            launchPath: launchPath,
            arguments: Array(sshArguments.dropFirst())
        )
    }

}
