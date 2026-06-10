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


// MARK: - Client connection, feedback, restore-session
extension CMUXCLI {
    func runFeedback(
        commandArgs: [String],
        socketPath: String,
        explicitPassword: String?,
        jsonOutput: Bool
    ) throws {
        let (emailOpt, rem0) = parseOption(commandArgs, name: "--email")
        let (bodyOpt, rem1) = parseOption(rem0, name: "--body")
        let (imagePaths, rem2) = parseRepeatedOption(rem1, name: "--image")
        let remaining = rem2.filter { $0 != "--" }

        if let unknown = remaining.first {
            throw CLIError(message: "feedback: unknown flag '\(unknown)'. Known flags: --email <email>, --body <text>, --image <path>")
        }

        let client = try connectClient(
            socketPath: socketPath,
            explicitPassword: explicitPassword,
            launchIfNeeded: true
        )
        defer { client.close() }

        if emailOpt == nil && bodyOpt == nil && imagePaths.isEmpty {
            var params: [String: Any] = [:]
            let env = ProcessInfo.processInfo.environment
            if let workspaceId = env["CMUX_WORKSPACE_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !workspaceId.isEmpty {
                params["workspace_id"] = workspaceId
                params["activate"] = false
            } else {
                params["activate"] = true
            }
            let response = try client.sendV2(method: "feedback.open", params: params)
            if jsonOutput {
                print(jsonString(response))
            } else {
                print("OK")
            }
            return
        }

        guard let email = emailOpt?.trimmingCharacters(in: .whitespacesAndNewlines),
              email.isEmpty == false else {
            throw CLIError(message: "feedback requires --email <email> when sending feedback")
        }
        guard let body = bodyOpt, body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw CLIError(message: "feedback requires --body <text> when sending feedback")
        }

        let resolvedImages = imagePaths.map(resolvePath)
        let response = try client.sendV2(method: "feedback.submit", params: [
            "email": email,
            "body": body,
            "image_paths": resolvedImages,
        ])
        if jsonOutput {
            print(jsonString(response))
        } else {
            print("OK")
        }
    }

    func runRestoreSession(
        commandArgs: [String],
        socketPath: String,
        explicitPassword: String?,
        jsonOutput: Bool
    ) throws {
        let remaining = commandArgs.filter { $0 != "--" }
        if let unknown = remaining.first {
            throw CLIError(message: "restore-session: unknown flag '\(unknown)'")
        }

        let initialClient = SocketClient(path: socketPath)
        let client: SocketClient
        let launched: Bool
        if (try? initialClient.connect()) == nil {
            initialClient.close()
            try launchApp()
            client = try SocketClient.waitForConnectableSocket(path: socketPath, timeout: 10)
            launched = true
        } else {
            client = initialClient
            launched = false
        }

        defer { client.close() }
        try authenticateClientIfNeeded(
            client,
            explicitPassword: explicitPassword,
            socketPath: socketPath
        )

        let response = try client.sendV2(method: "session.restore_previous")
        if jsonOutput {
            var payload = response
            payload["launched"] = launched
            print(jsonString(payload))
        } else {
            print("OK")
        }
    }

    func connectClient(
        socketPath: String,
        explicitPassword: String?,
        launchIfNeeded: Bool
    ) throws -> SocketClient {
        let client = SocketClient(path: socketPath)
        if launchIfNeeded && (try? client.connect()) == nil {
            client.close()
            try launchApp()
            let launchedClient = try SocketClient.waitForConnectableSocket(path: socketPath, timeout: 10)
            try authenticateClientIfNeeded(
                launchedClient,
                explicitPassword: explicitPassword,
                socketPath: socketPath
            )
            return launchedClient
        }

        try client.connect()
        try authenticateClientIfNeeded(
            client,
            explicitPassword: explicitPassword,
            socketPath: socketPath
        )
        return client
    }

    func authenticateClientIfNeeded(
        _ client: SocketClient,
        explicitPassword: String?,
        socketPath: String,
        responseTimeout: TimeInterval? = nil
    ) throws {
        try Self.authenticateSocketClientIfNeeded(
            client,
            explicitPassword: explicitPassword,
            socketPath: socketPath,
            responseTimeout: responseTimeout
        )
    }

    static func authenticateSocketClientIfNeeded(
        _ client: SocketClient,
        explicitPassword: String?,
        socketPath: String,
        responseTimeout: TimeInterval? = nil
    ) throws {
        if let socketPassword = SocketPasswordResolver.resolve(
            explicit: explicitPassword,
            socketPath: socketPath
        ) {
            let authResponse = try client.send(command: "auth \(socketPassword)", responseTimeout: responseTimeout)
            if authResponse.hasPrefix("ERROR:"),
               !authResponse.contains("Unknown command 'auth'") {
                throw CLIError(message: authResponse)
            }
        }
    }

    private func launchApp() throws {
        try runOpenTool(
            arguments: ["-a", appLaunchTarget()],
            failureMessage: String(localized: "cli.pathOpen.error.launchFailed", defaultValue: "Failed to launch cmux")
        )
    }

    func activateApp() throws {
        try runOpenTool(
            arguments: ["-a", appLaunchTarget()],
            failureMessage: String(localized: "cli.pathOpen.error.activateFailed", defaultValue: "Failed to activate cmux")
        )
    }

    func resolvedIDFormat(jsonOutput: Bool, raw: String?) throws -> CLIIDFormat {
        _ = jsonOutput
        if let parsed = try CLIIDFormat.parse(raw) {
            return parsed
        }
        return .refs
    }

    func sendV1Command(_ command: String, client: SocketClient) throws -> String {
        let response = try client.send(command: command)
        if response.hasPrefix("ERROR:") {
            throw CLIError(message: response)
        }
        return response
    }

}
