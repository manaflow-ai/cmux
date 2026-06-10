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


// MARK: - Sidebar commands
extension CMUXCLI {
    func forwardSidebarMetadataCommand(
        _ socketCommand: String,
        commandArgs: [String],
        client: SocketClient,
        windowOverride: String?
    ) throws -> String {
        func insertArgumentBeforeSeparator(_ value: String, into args: inout [String]) {
            if let separatorIndex = args.firstIndex(of: "--") {
                args.insert(value, at: separatorIndex)
            } else {
                args.append(value)
            }
        }

        var forwardedArgs: [String] = []
        var resolvedExplicitWorkspace = false
        var index = 0
        var parsingOptions = true
        let rawWindow = windowFromArgsOrOverride(commandArgs, windowOverride: windowOverride)
        let windowHandle = try normalizeWindowHandle(rawWindow, client: client)

        while index < commandArgs.count {
            let arg = commandArgs[index]
            if parsingOptions, arg == "--" {
                forwardedArgs.append(arg)
                parsingOptions = false
                index += 1
                continue
            }
            if parsingOptions, arg == "--workspace", index + 1 < commandArgs.count {
                let workspaceId = try resolveWorkspaceId(commandArgs[index + 1], client: client, windowHandle: windowHandle)
                forwardedArgs.append("--tab=\(workspaceId)")
                resolvedExplicitWorkspace = true
                index += 2
                continue
            }
            if parsingOptions, arg.hasPrefix("--workspace=") {
                let rawWorkspace = String(arg.dropFirst("--workspace=".count))
                let workspaceId = try resolveWorkspaceId(rawWorkspace, client: client, windowHandle: windowHandle)
                forwardedArgs.append("--tab=\(workspaceId)")
                resolvedExplicitWorkspace = true
                index += 1
                continue
            }
            if parsingOptions, arg == "--window", index + 1 < commandArgs.count {
                index += 2
                continue
            }
            if parsingOptions, arg.hasPrefix("--window=") {
                index += 1
                continue
            }
            forwardedArgs.append(arg)
            index += 1
        }

        if !resolvedExplicitWorkspace,
           let workspaceArg = workspaceFromArgsOrEnv(commandArgs, windowOverride: windowOverride) {
            let workspaceId = try resolveWorkspaceId(workspaceArg, client: client, windowHandle: windowHandle)
            insertArgumentBeforeSeparator("--tab=\(workspaceId)", into: &forwardedArgs)
        } else if !resolvedExplicitWorkspace,
                  let windowHandle {
            let workspaceId = try requireCurrentWorkspaceId(
                windowHandle: windowHandle,
                client: client,
                command: socketCommand
            )
            insertArgumentBeforeSeparator("--tab=\(workspaceId)", into: &forwardedArgs)
        }

        let command = ([socketCommand] + forwardedArgs)
            .map(shellQuote)
            .joined(separator: " ")
        return try sendV1Command(command, client: client)
    }

    struct RightSidebarCLIArguments {
        let positional: [String]
        let workspace: String?
        let window: String?
        let noFocus: Bool
    }

    func forwardRightSidebarCommand(
        commandArgs: [String],
        client: SocketClient,
        windowOverride: String?
    ) throws {
        let parsed = try parseRightSidebarCLIArguments(commandArgs)
        let socketArgs = try rightSidebarSocketArguments(from: parsed)
        let windowId = try resolveRightSidebarWindowId(parsed.window ?? windowOverride, client: client)
        let workspaceId = try resolveRightSidebarWorkspaceId(parsed.workspace, windowId: windowId, client: client)

        var forwardedArgs = socketArgs
        if let workspaceId {
            forwardedArgs.append("--tab=\(workspaceId)")
        }
        if let windowId {
            forwardedArgs.append("--window=\(windowId)")
        }

        let command = (["right_sidebar"] + forwardedArgs)
            .map(shellQuote)
            .joined(separator: " ")
        let response = try sendV1Command(command, client: client)
        if parsed.positional.first?.lowercased() == "mode" {
            print(response)
        }
    }

    func runSidebarCommand(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput inheritedJSONOutput: Bool
    ) throws {
        var args = commandArgs
        var jsonOutput = inheritedJSONOutput
        var explicitAll = false
        args.removeAll { arg in
            if arg == "--json" {
                jsonOutput = true
                return true
            }
            if arg == "--all" {
                explicitAll = true
                return true
            }
            return false
        }

        guard let action = args.first?.lowercased() else {
            throw CLIError(
                message: String(
                    localized: "cli.sidebar.error.missingCommand",
                    defaultValue: "sidebar requires a subcommand: validate, reload, or select"
                )
            )
        }

        let remaining = Array(args.dropFirst())
        let method: String
        var params: [String: Any] = [:]

        switch action {
        case "validate", "reload":
            guard remaining.count <= 1 else {
                throw CLIError(
                    message: String(
                        format: String(
                            localized: "cli.sidebar.error.unexpectedArguments",
                            defaultValue: "sidebar %@ accepts at most one sidebar name"
                        ),
                        action
                    )
                )
            }
            guard !(explicitAll && !remaining.isEmpty) else {
                throw CLIError(
                    message: String(
                        format: String(
                            localized: "cli.sidebar.error.allWithName",
                            defaultValue: "sidebar %@: use either --all or a sidebar name, not both"
                        ),
                        action
                    )
                )
            }
            if let name = remaining.first { params["name"] = name }
            method = action == "validate" ? "sidebar.custom.validate" : "sidebar.custom.reload"

        case "select":
            guard !explicitAll else {
                throw CLIError(
                    message: String(
                        localized: "cli.sidebar.error.selectAll",
                        defaultValue: "sidebar select does not support --all"
                    )
                )
            }
            guard remaining.count == 1 else {
                throw CLIError(
                    message: String(
                        localized: "cli.sidebar.error.selectRequiresName",
                        defaultValue: "sidebar select requires one sidebar name"
                    )
                )
            }
            params["name"] = remaining[0]
            method = "sidebar.custom.select"

        default:
            throw CLIError(
                message: String(
                    format: String(
                        localized: "cli.sidebar.error.unknownCommand",
                        defaultValue: "Unknown sidebar command '%@'"
                    ),
                    action
                )
            )
        }

        let payload = try client.sendV2(method: method, params: params)
        if jsonOutput {
            print(jsonString(payload))
        } else {
            printSidebarReport(payload, action: action)
        }

        let errorCount = intValue(payload["error_count"])
        if errorCount > 0 {
            exit(1)
        }
    }

    private func printSidebarReport(_ payload: [String: Any], action: String) {
        let sidebars = payload["sidebars"] as? [[String: Any]] ?? []
        if sidebars.isEmpty {
            print(String(localized: "cli.sidebar.noSidebars", defaultValue: "No custom sidebars found."))
        }
        for sidebar in sidebars {
            let name = (sidebar["name"] as? String) ?? "(unknown)"
            let path = (sidebar["path"] as? String) ?? ""
            let kind = (sidebar["kind"] as? String) ?? ""
            let ok = boolValue(sidebar["ok"])
            if ok {
                print(String(
                    format: String(localized: "cli.sidebar.report.ok", defaultValue: "OK %@ [%@] %@"),
                    name,
                    kind,
                    path
                ))
            } else {
                let error = (sidebar["error"] as? String) ?? String(localized: "cli.sidebar.unknownError", defaultValue: "Unknown error")
                print(String(
                    format: String(localized: "cli.sidebar.report.error", defaultValue: "ERROR %@ [%@] %@: %@"),
                    name,
                    kind,
                    path,
                    error
                ))
            }
        }

        let validCount = intValue(payload["valid_count"])
        let errorCount = intValue(payload["error_count"])
        if action == "reload" {
            let reloadedCount = intValue(payload["reloaded_count"])
            print(String(
                format: String(localized: "cli.sidebar.report.reloadSummary", defaultValue: "Reloaded %d valid sidebars. %d valid, %d invalid."),
                reloadedCount,
                validCount,
                errorCount
            ))
        } else if action == "select", let selectedName = payload["selected_name"] as? String {
            print(String(
                format: String(localized: "cli.sidebar.report.selected", defaultValue: "Selected %@."),
                selectedName
            ))
        } else {
            print(String(
                format: String(localized: "cli.sidebar.report.summary", defaultValue: "%d valid, %d invalid."),
                validCount,
                errorCount
            ))
        }
    }

    func intValue(_ raw: Any?) -> Int {
        if let value = Self.intValue(raw) { return value }
        if let value = raw as? String { return Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0 }
        return 0
    }

    func boolValue(_ raw: Any?) -> Bool {
        Self.boolValue(raw)
    }

    func parseRightSidebarCLIArguments(_ args: [String]) throws -> RightSidebarCLIArguments {
        var positional: [String] = []
        var workspace: String?
        var window: String?
        var noFocus = false
        var index = 0

        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--workspace":
                guard index + 1 < args.count else {
                    throw CLIError(message: String(localized: "cli.rightSidebar.error.workspaceRequiresValue", defaultValue: "right-sidebar: --workspace requires an id"))
                }
                workspace = args[index + 1]
                index += 2
            case "--window":
                guard index + 1 < args.count else {
                    throw CLIError(message: String(localized: "cli.rightSidebar.error.windowRequiresValue", defaultValue: "right-sidebar: --window requires an id"))
                }
                window = args[index + 1]
                index += 2
            case "--no-focus":
                noFocus = true
                index += 1
            default:
                if arg.hasPrefix("--workspace=") {
                    workspace = String(arg.dropFirst("--workspace=".count))
                    index += 1
                } else if arg.hasPrefix("--window=") {
                    window = String(arg.dropFirst("--window=".count))
                    index += 1
                } else if arg.hasPrefix("--") {
                    throw CLIError(message: String(localized: "cli.rightSidebar.error.unknownFlag", defaultValue: "right-sidebar: unknown flag '\(arg)'"))
                } else {
                    positional.append(arg)
                    index += 1
                }
            }
        }

        return RightSidebarCLIArguments(
            positional: positional,
            workspace: workspace,
            window: window,
            noFocus: noFocus
        )
    }

    func rightSidebarSocketArguments(from parsed: RightSidebarCLIArguments) throws -> [String] {
        guard let action = parsed.positional.first?.lowercased() else {
            throw CLIError(message: String(localized: "cli.rightSidebar.error.missingCommand", defaultValue: "right-sidebar requires a subcommand"))
        }

        switch action {
        case "toggle", "show", "hide", "focus", "mode":
            guard parsed.positional.count == 1 else {
                throw CLIError(message: String(localized: "cli.rightSidebar.error.unexpectedArguments", defaultValue: "right-sidebar \(action) received unexpected arguments"))
            }
            guard !parsed.noFocus else {
                throw CLIError(message: String(localized: "cli.rightSidebar.error.noFocusOnlySet", defaultValue: "right-sidebar: --no-focus is only valid with set"))
            }
            return [action]

        case "set":
            guard parsed.positional.count == 2 else {
                throw CLIError(message: String(localized: "cli.rightSidebar.error.setRequiresMode", defaultValue: "right-sidebar set requires a mode: files, find, vault, sessions, feed, or dock"))
            }
            let mode = parsed.positional[1].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard isRightSidebarCLIMode(mode) else {
                throw CLIError(message: String(localized: "cli.rightSidebar.error.unknownMode", defaultValue: "Unknown right-sidebar mode '\(parsed.positional[1])'"))
            }
            var args = ["set", mode]
            if parsed.noFocus {
                args.append("--no-focus")
            }
            return args

        case "files", "find", "vault", "sessions", "feed", "dock":
            guard parsed.positional.count == 1 else {
                throw CLIError(message: String(localized: "cli.rightSidebar.error.unexpectedArguments", defaultValue: "right-sidebar \(action) received unexpected arguments"))
            }
            guard !parsed.noFocus else {
                throw CLIError(message: String(localized: "cli.rightSidebar.error.noFocusOnlySet", defaultValue: "right-sidebar: --no-focus is only valid with set"))
            }
            return ["set", action]

        default:
            throw CLIError(message: String(localized: "cli.rightSidebar.error.unknownCommand", defaultValue: "Unknown right-sidebar command '\(action)'"))
        }
    }

    private func isRightSidebarCLIMode(_ value: String) -> Bool {
        switch value {
        case "files", "find", "vault", "sessions", "feed", "dock":
            return true
        default:
            return false
        }
    }

    private func resolveRightSidebarWindowId(_ raw: String?, client: SocketClient) throws -> String? {
        guard let normalized = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !normalized.isEmpty else { return nil }
        return try resolvedRightSidebarHandleID(
            normalized,
            expectedRefKind: "window",
            invalidMessage: String(localized: "cli.rightSidebar.error.invalidWindow", defaultValue: "Invalid window handle: \(normalized)"),
            missingRefMessage: String(localized: "cli.rightSidebar.error.windowRefNotFound", defaultValue: "Window ref not found"),
            listMethod: "window.list",
            listKey: "windows",
            client: client
        )
    }

    private func resolveRightSidebarWorkspaceId(
        _ raw: String?,
        windowId: String?,
        client: SocketClient
    ) throws -> String? {
        guard let normalized = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !normalized.isEmpty else { return nil }
        var params: [String: Any] = [:]
        if let windowId {
            params["window_id"] = windowId
        }
        return try resolvedRightSidebarHandleID(
            normalized,
            expectedRefKind: "workspace",
            invalidMessage: String(localized: "cli.rightSidebar.error.invalidWorkspace", defaultValue: "Invalid workspace handle: \(normalized)"),
            missingRefMessage: String(localized: "cli.rightSidebar.error.workspaceRefNotFound", defaultValue: "Workspace ref not found"),
            listMethod: "workspace.list",
            listKey: "workspaces",
            listParams: params,
            client: client
        )
    }

    private func resolvedRightSidebarHandleID(
        _ handle: String,
        expectedRefKind: String,
        invalidMessage: String,
        missingRefMessage: String,
        listMethod: String,
        listKey: String,
        listParams: [String: Any] = [:],
        client: SocketClient
    ) throws -> String {
        let trimmed = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        if isUUID(trimmed) { return trimmed }
        let refIndex: Int?
        if isHandleRef(trimmed) {
            let pieces = trimmed.split(separator: ":", omittingEmptySubsequences: false)
            guard pieces.count == 2, pieces[0].lowercased() == expectedRefKind else {
                throw CLIError(message: invalidMessage)
            }
            refIndex = Int(pieces[1])
        } else {
            refIndex = Int(trimmed)
        }

        let listed = try client.sendV2(method: listMethod, params: listParams)
        let items = listed[listKey] as? [[String: Any]] ?? []
        for item in items {
            guard let id = item["id"] as? String else { continue }
            if id == trimmed ||
                (item["ref"] as? String) == trimmed ||
                (refIndex != nil && intFromAny(item["index"]) == refIndex) {
                return id
            }
        }
        throw CLIError(message: missingRefMessage)
    }

    /// Pick the display handle for an item dict based on --id-format.
    func textHandle(_ item: [String: Any], idFormat: CLIIDFormat) -> String {
        let ref = item["ref"] as? String
        let id = item["id"] as? String
        switch idFormat {
        case .refs:  return ref ?? id ?? "?"
        case .uuids: return id ?? ref ?? "?"
        case .both:  return [ref, id].compactMap({ $0 }).joined(separator: " ")
        }
    }

    func v2OKSummary(_ payload: [String: Any], idFormat: CLIIDFormat, kinds: [String] = ["surface", "workspace"]) -> String {
        var parts = ["OK"]
        for kind in kinds {
            if let handle = formatHandle(payload, kind: kind, idFormat: idFormat) {
                parts.append(handle)
            }
        }
        return parts.joined(separator: " ")
    }

}
