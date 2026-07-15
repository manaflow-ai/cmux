import Foundation

extension CMUXCLI {
    func runWorkspaceListCommand(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowOverride: String?
    ) throws {
        var params: [String: Any] = [:]
        try applyWindowOrCallerContext(
            to: &params,
            client: client,
            windowRaw: windowFromArgsOrOverride(commandArgs, windowOverride: windowOverride)
        )
        let payload = try client.sendV2(method: "workspace.list", params: params)
        if jsonOutput {
            print(jsonString(formatIDs(payload, mode: idFormat)))
        } else {
            let workspaces = payload["workspaces"] as? [[String: Any]] ?? []
            if workspaces.isEmpty {
                print("No workspaces")
            } else {
                for ws in workspaces {
                    let selected = (ws["selected"] as? Bool) == true
                    let handle = textHandle(ws, idFormat: idFormat)
                    let title = (ws["title"] as? String) ?? ""
                    let remoteTag: String = {
                        guard let remote = ws["remote"] as? [String: Any],
                              (remote["enabled"] as? Bool) == true else {
                            return ""
                        }
                        let transport = (remote["transport"] as? String) ?? "remote"
                        let state = (remote["state"] as? String) ?? "unknown"
                        return "  [\(transport):\(state)]"
                    }()
                    let prefix = selected ? "* " : "  "
                    let selTag = selected ? "  [selected]" : ""
                    let titlePart = title.isEmpty ? "" : "  \(title)"
                    print("\(prefix)\(handle)\(titlePart)\(remoteTag)\(selTag)")
                }
            }
        }
    }

    func runWorkspaceCreateCommand(
        commandName: String,
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowOverride: String?,
        honorJSONOutput: Bool
    ) throws {
        let (commandOpt, rem0) = parseOption(commandArgs, name: "--command")
        let (cwdOpt, rem1) = parseOption(rem0, name: "--cwd")
        let (nameOpt, rem2) = parseOption(rem1, name: "--name")
        let (descriptionOpt, rem3) = parseOption(rem2, name: "--description")
        let (layoutOpt, rem4) = parseOption(rem3, name: "--layout")
        let (windowOpt, rem5) = parseOption(rem4, name: "--window")
        let (focusOpt, rem6) = parseOption(rem5, name: "--focus")
        let (groupOpt, rem7) = parseOption(rem6, name: "--group")
        let (groupPlacementOpt, rem8) = parseOption(rem7, name: "--group-placement")
        let (groupReferenceOpt, rem9) = parseOption(rem8, name: "--group-reference")
        let (envFiles, envPairs, remaining) = parseWorkspaceEnvOptions(rem9)
        if remaining.last == "--env" {
            throw CLIError(message: String(
                format: String(
                    localized: "cli.workspace.create.error.envRequiresValue",
                    defaultValue: "%@: --env requires KEY=VALUE"
                ),
                locale: .current,
                commandName
            ))
        }
        if remaining.last == "--env-file" {
            throw CLIError(message: String(
                format: String(
                    localized: "cli.workspace.create.error.envFileRequiresValue",
                    defaultValue: "%@: --env-file requires <path>"
                ),
                locale: .current,
                commandName
            ))
        }
        if let unknown = remaining.first(where: { $0.hasPrefix("--") }) {
            throw CLIError(message: String(
                format: String(
                    localized: "cli.workspace.create.error.unknownFlag",
                    defaultValue: "%@: unknown flag '%@'. Known flags: --name <title>, --description <text>, --command <text>, --cwd <path>, --env KEY=VALUE, --env-file <path>, --layout <json>, --window <id|ref|index>, --focus <true|false>, --group <id|ref>, --group-placement <afterCurrent|top|end>, --group-reference <workspace>"
                ),
                locale: .current,
                commandName,
                unknown
            ))
        }
        var params: [String: Any] = [:]
        try applyWindowOrCallerContext(to: &params, client: client, windowRaw: windowOpt ?? windowOverride)
        if let cwdOpt {
            params["cwd"] = resolvePath(cwdOpt)
        }
        if let nameOpt { params["title"] = nameOpt }
        if let descriptionOpt { params["description"] = descriptionOpt }
        if let groupOpt { params["group_id"] = groupOpt }
        if let groupPlacementOpt { params["group_placement"] = groupPlacementOpt }
        if let groupReferenceOpt { params["group_reference_workspace_id"] = groupReferenceOpt }
        let workspaceEnv = try buildWorkspaceEnvironment(envFiles: envFiles, envPairs: envPairs, commandName: commandName)
        if !workspaceEnv.isEmpty {
            params["workspace_env"] = workspaceEnv
        }
        if let layoutOpt {
            guard let layoutData = layoutOpt.data(using: .utf8),
                  let layoutObj = try? JSONSerialization.jsonObject(with: layoutData) as? [String: Any] else {
                throw CLIError(message: "\(commandName): --layout value must be a valid JSON object")
            }
            params["layout"] = layoutObj
        }
        try applyFocusOption(focusOpt, defaultValue: false, to: &params)
        let response = try client.sendV2(method: "workspace.create", params: params)
        let wsId = (response["workspace_ref"] as? String) ?? (response["workspace_id"] as? String) ?? ""
        if jsonOutput && honorJSONOutput {
            print(jsonString(formatIDs(response, mode: idFormat)))
        } else {
            print("OK \(wsId)")
        }
        if layoutOpt == nil, let commandText = commandOpt, !wsId.isEmpty {
            let text = unescapeSendText(commandText + "\\n")
            let sendParams: [String: Any] = [
                "text": text,
                "workspace_id": wsId
            ]
            _ = try client.sendV2(method: "surface.send_text", params: sendParams)
        }
    }

    /// Parses repeatable `--env KEY=VALUE` / `--env=KEY=VALUE` and
    /// `--env-file PATH` / `--env-file=PATH` flags out of `args`, returning the
    /// ordered env-file paths, the ordered `KEY=VALUE` pairs, and the remaining
    /// unparsed args. Files are applied before pairs by the builder so an explicit
    /// `--env` overrides a value from a file.
    func parseWorkspaceEnvOptions(
        _ args: [String]
    ) -> (envFiles: [String], envPairs: [String], remaining: [String]) {
        var envFiles: [String] = []
        var envPairs: [String] = []
        var remaining: [String] = []
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
            if !pastTerminator {
                if arg == "--env", idx + 1 < args.count {
                    envPairs.append(args[idx + 1])
                    skipNext = true
                    continue
                }
                if arg.hasPrefix("--env=") {
                    envPairs.append(String(arg.dropFirst("--env=".count)))
                    continue
                }
                if arg == "--env-file", idx + 1 < args.count {
                    envFiles.append(args[idx + 1])
                    skipNext = true
                    continue
                }
                if arg.hasPrefix("--env-file=") {
                    envFiles.append(String(arg.dropFirst("--env-file=".count)))
                    continue
                }
            }
            remaining.append(arg)
        }
        return (envFiles, envPairs, remaining)
    }

    /// Builds the workspace environment dict from `--env-file` paths (applied
    /// first, in order) and `--env KEY=VALUE` pairs (applied after, so they
    /// override files). Env files use `KEY=VALUE` lines; blank lines and lines
    /// starting with `#` are ignored, an optional leading `export ` is stripped,
    /// and matching surrounding quotes on a file value are removed. Command-line
    /// `--env` values are taken verbatim (the shell already handled quoting).
    func buildWorkspaceEnvironment(
        envFiles: [String],
        envPairs: [String],
        commandName: String
    ) throws -> [String: String] {
        var env: [String: String] = [:]
        for path in envFiles {
            let resolved = resolvePath(path)
            let contents: String
            do {
                contents = try String(contentsOfFile: resolved, encoding: .utf8)
            } catch {
                throw CLIError(message: String(
                    format: String(
                        localized: "cli.workspace.envFile.error.readFailed",
                        defaultValue: "%@: could not read --env-file '%@': %@"
                    ),
                    locale: .current,
                    commandName,
                    path,
                    String(describing: error)
                ))
            }
            for rawLine in contents.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline }) {
                var line = String(rawLine).trimmingCharacters(in: .whitespaces)
                if line.isEmpty || line.hasPrefix("#") { continue }
                if line.hasPrefix("export ") {
                    line = String(line.dropFirst("export ".count)).trimmingCharacters(in: .whitespaces)
                }
                let (key, value) = try parseEnvAssignment(line, source: "--env-file '\(path)'", commandName: commandName)
                env[key] = unquoteEnvValue(value)
            }
        }
        for pair in envPairs {
            let (key, value) = try parseEnvAssignment(pair, source: "--env", commandName: commandName)
            env[key] = value
        }
        return env
    }

    /// Splits a `KEY=VALUE` assignment on the first `=`. The key is trimmed and
    /// must be non-empty; the value is returned unmodified (callers decide whether
    /// to unquote).
    func parseEnvAssignment(
        _ raw: String,
        source: String,
        commandName: String
    ) throws -> (String, String) {
        guard let eq = raw.firstIndex(of: "=") else {
            throw CLIError(message: String(
                format: String(
                    localized: "cli.workspace.env.error.invalidAssignment",
                    defaultValue: "%@: %@ entry '%@' must be in KEY=VALUE form"
                ),
                locale: .current,
                commandName,
                source,
                raw
            ))
        }
        let key = String(raw[..<eq]).trimmingCharacters(in: .whitespaces)
        let value = String(raw[raw.index(after: eq)...])
        guard !key.isEmpty else {
            throw CLIError(message: String(
                format: String(
                    localized: "cli.workspace.env.error.emptyKey",
                    defaultValue: "%@: %@ entry '%@' has an empty key"
                ),
                locale: .current,
                commandName,
                source,
                raw
            ))
        }
        return (key, value)
    }

    /// Removes a single matching pair of surrounding single or double quotes from
    /// an env-file value.
    func unquoteEnvValue(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed.count >= 2,
           (trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"")) ||
           (trimmed.hasPrefix("'") && trimmed.hasSuffix("'")) {
            return String(trimmed.dropFirst().dropLast())
        }
        return trimmed
    }

    /// Masks a secret env value for display. Short values are fully masked so a
    /// brief secret isn't mostly revealed; longer ones keep a 2-character hint.
    /// The mask is fixed-width so the value's length isn't leaked.
    static func maskedEnvValue(_ value: String) -> String {
        if value.isEmpty { return "" }
        guard value.count > 6 else { return "••••" }
        return "\(value.prefix(2))••••"
    }

    /// `cmux workspace env [<handle>] [--mask]` — print a workspace's configured
    /// environment variables (issue #5995). Resolves the positional/`--workspace`
    /// handle, falling back to the selected workspace. `--mask` redacts values so
    /// secrets aren't echoed in full.
    func runWorkspaceEnvCommand(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowOverride: String?
    ) throws {
        var rest = commandArgs
        let mask = rest.contains("--mask")
        rest.removeAll { $0 == "--mask" }

        let (workspaceArg, rem0) = parseOption(rest, name: "--workspace")
        let (_, rem1) = parseOption(rem0, name: "--window")
        if let unknown = rem1.first(where: { $0.hasPrefix("--") }) {
            throw CLIError(message: String(
                format: String(
                    localized: "cli.workspace.env.error.unknownFlag",
                    defaultValue: "workspace env: unknown flag '%@'. Known flags: --workspace <id|ref|index>, --window <id|ref|index>, --mask"
                ),
                locale: .current,
                unknown
            ))
        }
        let positional = rem1.first(where: { !$0.hasPrefix("--") })
        let windowRaw = windowFromArgsOrOverride(commandArgs, windowOverride: windowOverride)
        // Match reconnect/disconnect: default to the caller's workspace
        // ($CMUX_WORKSPACE_ID) before the selected one, but only when no explicit
        // --window is given (the caller's workspace may live in another window).
        let target = workspaceArg
            ?? positional
            ?? (windowRaw == nil ? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] : nil)

        var params: [String: Any] = [:]
        let winId = try normalizeWindowHandle(windowRaw, client: client)
        if let winId { params["window_id"] = winId }
        let wsId = try normalizeWorkspaceHandle(target, client: client, windowHandle: winId)
        if let wsId { params["workspace_id"] = wsId }

        let payload = try client.sendV2(method: "workspace.env", params: params)
        let rawEnv = (payload["env"] as? [String: Any]) ?? [:]
        let envStrings: [String: String] = rawEnv.reduce(into: [:]) { result, pair in
            if let value = pair.value as? String { result[pair.key] = value }
        }
        let displayedEnv: [String: String] = mask
            ? envStrings.reduce(into: [String: String]()) { result, pair in
                result[pair.key] = Self.maskedEnvValue(pair.value)
            }
            : envStrings

        if jsonOutput {
            // Format only the envelope's id/ref metadata. The env map is arbitrary
            // user data, so running it through formatIDs (which strips `id` when
            // `ref` is present and `*_id` when a matching `*_ref` exists) could
            // silently drop a user variable; reinsert it verbatim after formatting.
            var envelope = payload
            envelope.removeValue(forKey: "env")
            var formatted = (formatIDs(envelope, mode: idFormat) as? [String: Any]) ?? envelope
            formatted["env"] = displayedEnv
            print(jsonString(formatted))
        } else if envStrings.isEmpty {
            print(String(localized: "cli.workspace.env.empty", defaultValue: "No environment variables"))
        } else {
            for key in envStrings.keys.sorted() {
                print("\(key)=\(displayedEnv[key] ?? "")")
            }
        }
    }
}
