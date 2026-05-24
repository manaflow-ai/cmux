import Foundation

extension CMUXCLI {
    private static let layoutPresetSchema = "cmux.workspacePreset.v1"

    func layoutCommandDoesNotNeedSocket(_ commandArgs: [String]) -> Bool {
        let subcommand = commandArgs.first?.lowercased() ?? "help"
        if subcommand == "help" || subcommand == "--help" || subcommand == "-h" {
            return true
        }
        if commandArgs.contains("--help") || commandArgs.contains("-h") {
            return true
        }
        return ["import", "list", "ls", "path"].contains(subcommand)
    }

    func runLayoutCommand(
        commandArgs: [String],
        client: SocketClient?,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        let subcommand = commandArgs.first?.lowercased() ?? "help"
        let args = Array(commandArgs.dropFirst())

        switch subcommand {
        case "help", "--help", "-h":
            print(layoutUsage())

        case "path":
            try runLayoutPath(commandArgs: args, jsonOutput: jsonOutput)

        case "list", "ls":
            try runLayoutList(commandArgs: args, jsonOutput: jsonOutput)

        case "import":
            try runLayoutImport(commandArgs: args, jsonOutput: jsonOutput)

        case "save":
            guard let client else {
                throw CLIError(message: "cmux layout save requires a running cmux socket")
            }
            try runLayoutSave(commandArgs: args, client: client, jsonOutput: jsonOutput, idFormat: idFormat)

        case "export":
            guard let client else {
                throw CLIError(message: "cmux layout export requires a running cmux socket")
            }
            try runLayoutExport(commandArgs: args, client: client, jsonOutput: jsonOutput)

        case "open":
            guard let client else {
                throw CLIError(message: "cmux layout open requires a running cmux socket")
            }
            try runLayoutOpen(commandArgs: args, client: client, jsonOutput: jsonOutput, idFormat: idFormat)

        default:
            throw CLIError(message: "Unknown layout subcommand: \(subcommand). Run `cmux layout --help`.")
        }
    }

    func layoutUsage() -> String {
        """
        Usage: cmux layout <save|open|export|import|list|path> [options]

        Manage named workspace layout presets stored under ~/.config/cmux/layouts.
        Presets use the same split layout schema as cmux.json workspace definitions,
        wrapped in a cmux.workspacePreset.v1 object. Exported JSON is valid YAML.

        Commands:
          save <name> [--workspace <id|ref|index>]
          open <name> [--cwd <path>] [--title <title>] [--focus <true|false>]
          export [--workspace <id|ref|index>] [--name <name>] [--out <path>]
          import <path> [--name <name>]
          list
          path

        Examples:
          cmux layout save dev
          cmux layout open dev
          cmux layout export --workspace workspace:2 > dev.yaml
          cmux layout import ./dev.yaml --name dev
          cmux layout list
        """
    }

    private func runLayoutPath(commandArgs: [String], jsonOutput: Bool) throws {
        let remaining = commandArgs.filter { $0 != "--json" }
        if let unknown = remaining.first {
            throw CLIError(message: "layout path: unexpected argument '\(unknown)'")
        }
        let path = layoutPresetDirectoryURL().path
        if jsonOutput {
            print(jsonString(["path": path]))
        } else {
            print(path)
        }
    }

    private func runLayoutList(commandArgs: [String], jsonOutput: Bool) throws {
        let remaining = commandArgs.filter { $0 != "--json" }
        if let unknown = remaining.first {
            throw CLIError(message: "layout list: unexpected argument '\(unknown)'")
        }

        let directory = layoutPresetDirectoryURL()
        let fileManager = FileManager.default
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            if jsonOutput {
                print(jsonString(["presets": []]))
            } else {
                print("No layout presets")
            }
            return
        }

        let presets: [[String: Any]] = urls
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { url -> [String: Any] in
                let name = url.deletingPathExtension().lastPathComponent
                var entry: [String: Any] = [
                    "name": name,
                    "path": url.path
                ]
                do {
                    let object = try layoutReadJSONObject(from: url)
                    let preset = try layoutCanonicalPreset(
                        from: object,
                        nameOverride: nil,
                        fallbackName: name,
                        commandName: "layout list"
                    )
                    if let workspace = preset["workspace"] as? [String: Any] {
                        if let workspaceName = layoutNonEmptyString(workspace["name"]) {
                            entry["workspace_name"] = workspaceName
                        }
                        if let cwd = layoutNonEmptyString(workspace["cwd"]) {
                            entry["cwd"] = cwd
                        }
                    }
                } catch {
                    entry["error"] = error.localizedDescription
                }
                return entry
            }

        if jsonOutput {
            print(jsonString(["presets": presets]))
            return
        }

        if presets.isEmpty {
            print("No layout presets")
            return
        }

        for preset in presets {
            let name = (preset["name"] as? String) ?? "?"
            let cwd = (preset["cwd"] as? String).map { "  \($0)" } ?? ""
            let error = (preset["error"] as? String).map { "  [invalid: \($0)]" } ?? ""
            print("\(name)\(cwd)\(error)")
        }
    }

    private func runLayoutImport(commandArgs: [String], jsonOutput: Bool) throws {
        let (nameOpt, rem0) = parseOption(commandArgs, name: "--name")
        if let unknown = rem0.first(where: { $0.hasPrefix("--") }) {
            throw CLIError(message: "layout import: unknown flag '\(unknown)'. Known flags: --name <name>")
        }
        let positional = rem0.filter { $0 != "--" && !$0.hasPrefix("-") }
        guard positional.count == 1, let path = positional.first else {
            throw CLIError(message: "Usage: cmux layout import <path> [--name <name>]")
        }

        let sourceURL = URL(fileURLWithPath: resolvePath(path))
        let fallbackName = sourceURL.deletingPathExtension().lastPathComponent
        let object = try layoutReadJSONObject(from: sourceURL)
        let preset = try layoutCanonicalPreset(
            from: object,
            nameOverride: nameOpt,
            fallbackName: fallbackName,
            commandName: "layout import"
        )
        let name = try layoutPresetName(preset["name"] as? String, commandName: "layout import")
        let destinationURL = layoutPresetURL(name: name)
        try layoutWriteJSONObject(preset, to: destinationURL)

        let payload: [String: Any] = [
            "ok": true,
            "name": name,
            "path": destinationURL.path
        ]
        if jsonOutput {
            print(jsonString(payload))
        } else {
            print("OK \(name) \(destinationURL.path)")
        }
    }

    private func runLayoutSave(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        let (workspaceOpt, rem0) = parseOption(commandArgs, name: "--workspace")
        let (nameOpt, rem1) = parseOption(rem0, name: "--name")
        if let unknown = rem1.first(where: { $0.hasPrefix("--") }) {
            throw CLIError(message: "layout save: unknown flag '\(unknown)'. Known flags: --workspace <id|ref|index>, --name <name>")
        }
        let positional = rem1.filter { $0 != "--" && !$0.hasPrefix("-") }
        let rawName = nameOpt ?? positional.first
        guard positional.count <= 1 else {
            throw CLIError(message: "Usage: cmux layout save <name> [--workspace <id|ref|index>]")
        }
        let name = try layoutPresetName(rawName, commandName: "layout save")

        var params: [String: Any] = ["name": name]
        if let workspaceId = try normalizeWorkspaceHandle(workspaceOpt, client: client) {
            params["workspace_id"] = workspaceId
        }

        let exported = try client.sendV2(method: "workspace.layout_export", params: params)
        let preset = try layoutCanonicalPreset(
            from: exported,
            nameOverride: name,
            fallbackName: name,
            commandName: "layout save"
        )
        let destinationURL = layoutPresetURL(name: name)
        try layoutWriteJSONObject(preset, to: destinationURL)

        let payload: [String: Any] = [
            "ok": true,
            "name": name,
            "path": destinationURL.path,
            "workspace": formatIDs(exported, mode: idFormat)
        ]
        if jsonOutput {
            print(jsonString(payload))
        } else {
            print("OK \(name) \(destinationURL.path)")
        }
    }

    private func runLayoutExport(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool
    ) throws {
        let (workspaceOpt, rem0) = parseOption(commandArgs, name: "--workspace")
        let (nameOpt, rem1) = parseOption(rem0, name: "--name")
        let (outOpt, rem2) = parseOption(rem1, name: "--out")
        let (outputOpt, rem3) = parseOption(rem2, name: "--output")
        if let unknown = rem3.first(where: { $0.hasPrefix("--") }) {
            throw CLIError(message: "layout export: unknown flag '\(unknown)'. Known flags: --workspace <id|ref|index>, --name <name>, --out <path>")
        }
        if let extra = rem3.first(where: { $0 != "--" }) {
            throw CLIError(message: "layout export: unexpected argument '\(extra)'")
        }

        var params: [String: Any] = [:]
        let requestedName = try nameOpt.map { try layoutPresetName($0, commandName: "layout export") }
        if let requestedName {
            params["name"] = requestedName
        }
        if let workspaceId = try normalizeWorkspaceHandle(workspaceOpt, client: client) {
            params["workspace_id"] = workspaceId
        }

        let exported = try client.sendV2(method: "workspace.layout_export", params: params)
        let preset = try layoutCanonicalPreset(
            from: exported,
            nameOverride: requestedName,
            fallbackName: "workspace",
            commandName: "layout export"
        )

        if let outputPath = outOpt ?? outputOpt {
            let url = URL(fileURLWithPath: resolvePath(outputPath))
            try layoutWriteJSONObject(preset, to: url)
            let payload: [String: Any] = [
                "ok": true,
                "name": (preset["name"] as? String) ?? "",
                "path": url.path
            ]
            if jsonOutput {
                print(jsonString(payload))
            } else {
                print("OK \(url.path)")
            }
            return
        }

        print(jsonString(preset))
    }

    private func runLayoutOpen(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        let (nameOpt, rem0) = parseOption(commandArgs, name: "--name")
        let (cwdOpt, rem1) = parseOption(rem0, name: "--cwd")
        let (titleOpt, rem2) = parseOption(rem1, name: "--title")
        let (focusOpt, rem3) = parseOption(rem2, name: "--focus")
        if let unknown = rem3.first(where: { $0.hasPrefix("--") }) {
            throw CLIError(message: "layout open: unknown flag '\(unknown)'. Known flags: --name <name>, --cwd <path>, --title <title>, --focus <true|false>")
        }
        let positional = rem3.filter { $0 != "--" && !$0.hasPrefix("-") }
        let rawName = nameOpt ?? positional.first
        guard positional.count <= 1 else {
            throw CLIError(message: "Usage: cmux layout open <name> [--cwd <path>] [--title <title>] [--focus <true|false>]")
        }
        let name = try layoutPresetName(rawName, commandName: "layout open")
        let sourceURL = layoutPresetURL(name: name)
        let object = try layoutReadJSONObject(from: sourceURL)
        let preset = try layoutCanonicalPreset(
            from: object,
            nameOverride: nil,
            fallbackName: name,
            commandName: "layout open"
        )

        let params = try layoutWorkspaceCreateParams(
            from: preset,
            cwdOverride: cwdOpt,
            titleOverride: titleOpt,
            focusOpt: focusOpt
        )
        let response = try client.sendV2(method: "workspace.create", params: params)
        printV2Payload(
            response,
            jsonOutput: jsonOutput,
            idFormat: idFormat,
            fallbackText: v2OKSummary(response, idFormat: idFormat, kinds: ["workspace"])
        )
    }

    private func layoutPresetDirectoryURL() -> URL {
        let envOverride = ProcessInfo.processInfo.environment["CMUX_LAYOUT_PRESET_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let path: String
        if let envOverride, !envOverride.isEmpty {
            path = resolvePath(envOverride)
        } else {
            path = NSString(string: "~/.config/cmux/layouts").expandingTildeInPath
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private func layoutPresetURL(name: String) -> URL {
        layoutPresetDirectoryURL()
            .appendingPathComponent(name, isDirectory: false)
            .appendingPathExtension("json")
    }

    private func layoutPresetName(_ raw: String?, commandName: String) throws -> String {
        guard let raw else {
            throw CLIError(message: "\(commandName) requires a preset name")
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CLIError(message: "\(commandName) requires a non-empty preset name")
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        guard trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw CLIError(message: "Preset names may contain only letters, numbers, '.', '_', and '-'")
        }
        guard !trimmed.contains("..") else {
            throw CLIError(message: "Preset names may not contain '..'")
        }
        return trimmed
    }

    private func layoutPresetNameFromCandidate(
        _ raw: String?,
        fallbackName: String,
        commandName: String
    ) throws -> String {
        if let raw {
            if let valid = try? layoutPresetName(raw, commandName: commandName) {
                return valid
            }
            let sanitized = sanitizedFilenameComponent(raw)
            if let valid = try? layoutPresetName(sanitized, commandName: commandName) {
                return valid
            }
        }

        if let valid = try? layoutPresetName(fallbackName, commandName: commandName) {
            return valid
        }
        return try layoutPresetName(
            sanitizedFilenameComponent(fallbackName),
            commandName: commandName
        )
    }

    private func layoutReadJSONObject(from url: URL) throws -> [String: Any] {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw CLIError(message: "Failed to read \(url.path): \(error.localizedDescription)")
        }

        let sanitized: Data
        do {
            sanitized = try JSONCParser.preprocess(data: data)
        } catch {
            throw CLIError(message: "Failed to parse \(url.path): JSONC preprocessing failed")
        }

        do {
            guard let object = try JSONSerialization.jsonObject(with: sanitized, options: []) as? [String: Any] else {
                throw CLIError(message: "\(url.path) must contain a JSON object")
            }
            return object
        } catch let error as CLIError {
            throw error
        } catch {
            throw CLIError(message: "Failed to parse \(url.path): \(error.localizedDescription)")
        }
    }

    private func layoutWriteJSONObject(_ object: [String: Any], to url: URL) throws {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw CLIError(message: "Layout preset is not a valid JSON object")
        }
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var options: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys]
        options.insert(.withoutEscapingSlashes)
        let data = try JSONSerialization.data(withJSONObject: object, options: options)
        try data.write(to: url, options: .atomic)
    }

    private func layoutCanonicalPreset(
        from object: [String: Any],
        nameOverride: String?,
        fallbackName: String,
        commandName: String
    ) throws -> [String: Any] {
        let workspace: [String: Any]
        let discoveredName: String?

        if let workspaceObject = object["workspace"] as? [String: Any] {
            workspace = workspaceObject
            discoveredName = layoutNonEmptyString(object["name"])
                ?? layoutNonEmptyString(workspaceObject["name"])
        } else if let layout = object["layout"] as? [String: Any] {
            var workspaceObject = object
            workspaceObject["layout"] = layout
            workspaceObject.removeValue(forKey: "schema")
            workspaceObject.removeValue(forKey: "workspace_id")
            workspaceObject.removeValue(forKey: "workspace_ref")
            workspaceObject.removeValue(forKey: "window_id")
            workspaceObject.removeValue(forKey: "window_ref")
            workspace = workspaceObject
            discoveredName = layoutNonEmptyString(object["name"])
        } else if object["pane"] != nil || object["direction"] != nil {
            workspace = ["layout": object]
            discoveredName = nil
        } else {
            throw CLIError(message: "\(commandName): preset must contain workspace.layout or a layout root object")
        }

        let name: String
        if let nameOverride {
            name = try layoutPresetName(nameOverride, commandName: commandName)
        } else {
            name = try layoutPresetNameFromCandidate(
                discoveredName,
                fallbackName: fallbackName,
                commandName: commandName
            )
        }
        guard let layout = workspace["layout"] as? [String: Any] else {
            throw CLIError(message: "\(commandName): preset workspace must include a layout object")
        }

        var canonicalWorkspace = workspace
        canonicalWorkspace["layout"] = layout
        if layoutNonEmptyString(canonicalWorkspace["name"]) == nil {
            canonicalWorkspace["name"] = name
        }

        return [
            "schema": Self.layoutPresetSchema,
            "name": name,
            "workspace": canonicalWorkspace
        ]
    }

    private func layoutWorkspaceCreateParams(
        from preset: [String: Any],
        cwdOverride: String?,
        titleOverride: String?,
        focusOpt: String?
    ) throws -> [String: Any] {
        guard let workspace = preset["workspace"] as? [String: Any],
              let layout = workspace["layout"] as? [String: Any] else {
            throw CLIError(message: "Preset must include workspace.layout")
        }

        var params: [String: Any] = ["layout": layout]
        if let title = layoutNonEmptyString(titleOverride)
            ?? layoutNonEmptyString(workspace["name"])
            ?? layoutNonEmptyString(preset["name"]) {
            params["title"] = title
        }
        if let cwd = layoutNonEmptyString(cwdOverride)
            ?? layoutNonEmptyString(workspace["cwd"]) {
            params["cwd"] = resolvePath(cwd)
        }
        if let color = layoutNonEmptyString(workspace["color"]) {
            params["color"] = color
        }
        try applyFocusOption(focusOpt, defaultValue: false, to: &params)
        return params
    }

    private func layoutNonEmptyString(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return nil
    }

    func sanitizedFilenameComponent(_ raw: String) -> String {
        let sanitized = raw.replacingOccurrences(
            of: #"[^\p{L}\p{N}._-]+"#,
            with: "-",
            options: .regularExpression
        )
        let trimmed = sanitized.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return trimmed.isEmpty ? "item" : trimmed
    }
}
