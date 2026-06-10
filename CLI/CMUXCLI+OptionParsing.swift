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


// MARK: - CLI option parsing and caller context
extension CMUXCLI {
    /// Dispatch help for a subcommand. Returns true if help was printed.
    func dispatchSubcommandHelp(command: String, commandArgs: [String]) -> Bool {
        guard commandArgs.contains("--help") || commandArgs.contains("-h") else { return false }
        guard let text = subcommandUsage(command) else { return false }
        print("cmux \(command)")
        print("")
        print(text)
        return true
    }

    /// Escape and quote a string for safe embedding in a v1 socket command.
    /// The socket tokenizer treats `\` and `"` as special inside quoted strings,
    /// so both must be escaped before wrapping in double quotes. Newlines and
    /// carriage returns must also be escaped since the socket protocol uses
    /// newline as the message terminator.
    private func socketQuote(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        return "\"\(escaped)\""
    }
    func parseOption(_ args: [String], name: String) -> (String?, [String]) {
        var remaining: [String] = []
        var value: String?
        var skipNext = false
        var pastTerminator = false
        for (idx, arg) in args.enumerated() {
            if skipNext {
                skipNext = false
                continue
            }
            if arg == "--" {
                pastTerminator = true
                remaining.append(arg)
                continue
            }
            if !pastTerminator, arg.hasPrefix("\(name)=") {
                value = String(arg.dropFirst(name.count + 1))
                continue
            }
            if !pastTerminator, arg == name, idx + 1 < args.count {
                value = args[idx + 1]
                skipNext = true
                continue
            }
            remaining.append(arg)
        }
        return (value, remaining)
    }

    func parseRepeatedOption(_ args: [String], name: String) -> ([String], [String]) {
        var remaining: [String] = []
        var values: [String] = []
        var skipNext = false
        var pastTerminator = false
        for (idx, arg) in args.enumerated() {
            if skipNext {
                skipNext = false
                continue
            }
            if arg == "--" {
                pastTerminator = true
                remaining.append(arg)
                continue
            }
            if !pastTerminator, arg == name, idx + 1 < args.count {
                values.append(args[idx + 1])
                skipNext = true
                continue
            }
            remaining.append(arg)
        }
        return (values, remaining)
    }

    func optionValue(_ args: [String], name: String) -> String? {
        for (index, arg) in args.enumerated() {
            if arg == "--" { return nil }
            if arg == name, index + 1 < args.count {
                return args[index + 1]
            }
            if arg.hasPrefix("\(name)=") {
                return String(arg.dropFirst(name.count + 1))
            }
        }
        return nil
    }

    func hasFlag(_ args: [String], name: String) -> Bool {
        args.contains(name)
    }

    func replaceToken(_ args: [String], from: String, to: String) -> [String] {
        args.map { $0 == from ? to : $0 }
    }

    /// Unescape CLI escape sequences to match legacy v1 send behavior.
    /// \n and \r → carriage return (Enter), \t → tab.
    func unescapeSendText(_ text: String) -> String {
        return text
            .replacingOccurrences(of: "\\n", with: "\r")
            .replacingOccurrences(of: "\\r", with: "\r")
            .replacingOccurrences(of: "\\t", with: "\t")
    }

    func workspaceFromArgsOrEnv(_ args: [String], windowOverride: String? = nil) -> String? {
        if let explicit = optionValue(args, name: "--workspace") { return explicit }
        // When --window is explicitly targeted, don't fall back to env workspace from a different window
        if windowOverride != nil || optionValue(args, name: "--window") != nil { return nil }
        return ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"]
    }

    func windowFromArgsOrOverride(_ args: [String], windowOverride: String? = nil) -> String? {
        optionValue(args, name: "--window") ?? windowOverride
    }

    func applyWindowOrCallerContext(to params: inout [String: Any], client: SocketClient, windowRaw: String?) throws {
        if let windowHandle = try normalizeWindowHandle(windowRaw, client: client) {
            params["window_id"] = windowHandle
            return
        }

        let env = ProcessInfo.processInfo.environment
        let workspaceHandle = try normalizeWorkspaceHandle(env["CMUX_WORKSPACE_ID"], client: client)
        if let workspaceHandle {
            params["workspace_id"] = workspaceHandle
        }
        let surfaceHandle = try normalizeSurfaceHandle(env["CMUX_SURFACE_ID"], client: client, workspaceHandle: workspaceHandle)
        if let surfaceHandle {
            params["surface_id"] = surfaceHandle
        }
    }

    private func currentWorkspaceId(windowHandle: String, client: SocketClient) throws -> String? {
        let payload = try client.sendV2(method: "workspace.current", params: ["window_id": windowHandle])
        let workspaceId = (payload["workspace_id"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let workspaceId, !workspaceId.isEmpty else { return nil }
        return workspaceId
    }

    func requireCurrentWorkspaceId(
        windowHandle: String,
        client: SocketClient,
        command: String
    ) throws -> String {
        if let workspaceId = try currentWorkspaceId(windowHandle: windowHandle, client: client) {
            return workspaceId
        }
        let commandLabel = command.replacingOccurrences(of: "_", with: "-")
        throw CLIError(message: "\(commandLabel): targeted window has no current workspace. Select a workspace in that window or pass --workspace <id|ref|index>.")
    }

}
