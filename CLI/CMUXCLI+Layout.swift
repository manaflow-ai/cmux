import Foundation

extension CMUXCLI {
    private static let layoutPresetSchema = "cmux.workspacePreset.v1"

    func layoutCommandDoesNotNeedSocket(_ commandArgs: [String]) -> Bool {
        let command = layoutCommandParts(commandArgs)
        if layoutCommandIsHelp(command.subcommand) {
            return true
        }
        if layoutHelpFlagRequested(subcommand: command.subcommand, args: command.args) {
            return true
        }
        return ["import", "list", "ls", "path"].contains(command.subcommand)
    }

    func runLayoutCommand(
        commandArgs: [String],
        client: SocketClient?,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        let command = layoutCommandParts(commandArgs)
        let subcommand = command.subcommand
        let args = command.args

        if layoutHelpFlagRequested(subcommand: subcommand, args: args) {
            print(layoutUsage())
            return
        }

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
                throw CLIError(message: String.localizedStringWithFormat(
                    String(localized: "cli.layout.error.socketRequired", defaultValue: "%@ requires a running cmux socket"),
                    "cmux layout save"
                ))
            }
            try runLayoutSave(commandArgs: args, client: client, jsonOutput: jsonOutput, idFormat: idFormat)

        case "export":
            guard let client else {
                throw CLIError(message: String.localizedStringWithFormat(
                    String(localized: "cli.layout.error.socketRequired", defaultValue: "%@ requires a running cmux socket"),
                    "cmux layout export"
                ))
            }
            try runLayoutExport(commandArgs: args, client: client, jsonOutput: jsonOutput)

        case "open":
            guard let client else {
                throw CLIError(message: String.localizedStringWithFormat(
                    String(localized: "cli.layout.error.socketRequired", defaultValue: "%@ requires a running cmux socket"),
                    "cmux layout open"
                ))
            }
            try runLayoutOpen(commandArgs: args, client: client, jsonOutput: jsonOutput, idFormat: idFormat)

        default:
            throw CLIError(message: String.localizedStringWithFormat(
                String(localized: "cli.layout.error.unknownSubcommand", defaultValue: "Unknown layout subcommand: %@. Run `cmux layout --help`."),
                subcommand
            ))
        }
    }

    func layoutUsage() -> String {
        String(localized: "cli.layout.usage", defaultValue: """
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
        """)
    }

    private func layoutCommandParts(_ commandArgs: [String]) -> (subcommand: String, args: [String]) {
        guard let first = commandArgs.first, first != "--" else {
            return ("help", Array(commandArgs.dropFirst()))
        }
        return (first.lowercased(), Array(commandArgs.dropFirst()))
    }

    private func layoutCommandIsHelp(_ subcommand: String) -> Bool {
        subcommand == "help" || subcommand == "--help" || subcommand == "-h"
    }

    private func layoutHelpFlagRequested(subcommand: String, args: [String]) -> Bool {
        let valueOptions = layoutValueOptions(for: subcommand)
        var index = 0
        while index < args.count {
            let arg = args[index]
            if arg == "--" {
                return false
            }
            if arg == "--help" || arg == "-h" {
                return true
            }
            if let equalsIndex = arg.firstIndex(of: "=") {
                let option = String(arg[..<equalsIndex])
                if valueOptions.contains(option) {
                    index += 1
                    continue
                }
            }
            if valueOptions.contains(arg), index + 1 < args.count {
                index += 2
                continue
            }
            index += 1
        }
        return false
    }

    private func layoutValueOptions(for subcommand: String) -> Set<String> {
        switch subcommand {
        case "import":
            return ["--name"]
        case "save":
            return ["--workspace", "--name"]
        case "export":
            return ["--workspace", "--name", "--out", "--output"]
        case "open":
            return ["--name", "--cwd", "--title", "--focus"]
        default:
            return []
        }
    }

    private func layoutUnknownLongFlag(in args: [String]) -> String? {
        for arg in args {
            if arg == "--" {
                return nil
            }
            if arg.hasPrefix("--") {
                return arg
            }
        }
        return nil
    }

    private func layoutPositionalArguments(from args: [String]) -> [String] {
        args.filter { $0 != "--" }
    }

    private func runLayoutPath(commandArgs: [String], jsonOutput: Bool) throws {
        let remaining = commandArgs.filter { $0 != "--json" }
        if let unknown = remaining.first {
            throw CLIError(message: String.localizedStringWithFormat(
                String(localized: "cli.layout.error.unexpectedArgument", defaultValue: "%@: unexpected argument '%@'"),
                "layout path",
                unknown
            ))
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
            throw CLIError(message: String.localizedStringWithFormat(
                String(localized: "cli.layout.error.unexpectedArgument", defaultValue: "%@: unexpected argument '%@'"),
                "layout list",
                unknown
            ))
        }

        let presetDirectory = layoutPresetDirectory()
        let directory = presetDirectory.url
        let fileManager = FileManager.default
        if !presetDirectory.fromEnvironment,
           !fileManager.fileExists(atPath: directory.path) {
            printLayoutNoPresets(jsonOutput: jsonOutput)
            return
        }
        let urls: [URL]
        do {
            urls = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw CLIError(message: String.localizedStringWithFormat(
                String(localized: "cli.layout.error.listReadFailed", defaultValue: "Failed to read layout preset directory %@"),
                directory.path
            ))
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
                    layoutDebugLogInvalidPresetListEntry(url: url, error: error)
                    entry["error"] = String(localized: "cli.layout.output.invalidPresetStatus", defaultValue: "invalid preset")
                }
                return entry
            }

        if jsonOutput {
            print(jsonString(["presets": presets]))
            return
        }

        if presets.isEmpty {
            printLayoutNoPresets(jsonOutput: jsonOutput)
            return
        }

        for preset in presets {
            let name = (preset["name"] as? String) ?? "?"
            let cwd = (preset["cwd"] as? String).map { "  \($0)" } ?? ""
            let error = (preset["error"] as? String).map {
                String.localizedStringWithFormat(
                    String(localized: "cli.layout.output.invalidPresetSuffix", defaultValue: "  [invalid: %@]"),
                    $0
                )
            } ?? ""
            print("\(name)\(cwd)\(error)")
        }
    }

    private func printLayoutNoPresets(jsonOutput: Bool) {
        if jsonOutput {
            print(jsonString(["presets": []]))
        } else {
            print(String(localized: "cli.layout.output.noPresets", defaultValue: "No layout presets"))
        }
    }

    private func runLayoutImport(commandArgs: [String], jsonOutput: Bool) throws {
        let (nameOpt, rem0) = parseOption(commandArgs, name: "--name")
        if let unknown = layoutUnknownLongFlag(in: rem0) {
            throw CLIError(message: String.localizedStringWithFormat(
                String(localized: "cli.layout.error.unknownFlagKnownFlags", defaultValue: "%@: unknown flag '%@'. Known flags: %@"),
                "layout import",
                unknown,
                "--name <name>"
            ))
        }
        let positional = layoutPositionalArguments(from: rem0)
        guard positional.count == 1, let path = positional.first else {
            throw CLIError(message: String(localized: "cli.layout.error.importUsage", defaultValue: "Usage: cmux layout import <path> [--name <name>]"))
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
            print(String.localizedStringWithFormat(
                String(localized: "cli.layout.output.okNamePath", defaultValue: "OK %@ %@"),
                name,
                destinationURL.path
            ))
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
        if let unknown = layoutUnknownLongFlag(in: rem1) {
            throw CLIError(message: String.localizedStringWithFormat(
                String(localized: "cli.layout.error.unknownFlagKnownFlags", defaultValue: "%@: unknown flag '%@'. Known flags: %@"),
                "layout save",
                unknown,
                "--workspace <id|ref|index>, --name <name>"
            ))
        }
        let positional = layoutPositionalArguments(from: rem1)
        let rawName: String?
        if let nameOpt {
            if let extra = positional.first {
                throw CLIError(message: String.localizedStringWithFormat(
                    String(localized: "cli.layout.error.unexpectedArgument", defaultValue: "%@: unexpected argument '%@'"),
                    "layout save",
                    extra
                ))
            }
            rawName = nameOpt
        } else {
            guard positional.count <= 1 else {
                throw CLIError(message: String(localized: "cli.layout.error.saveUsage", defaultValue: "Usage: cmux layout save <name> [--workspace <id|ref|index>]"))
            }
            rawName = positional.first
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
            print(String.localizedStringWithFormat(
                String(localized: "cli.layout.output.okNamePath", defaultValue: "OK %@ %@"),
                name,
                destinationURL.path
            ))
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
        if let unknown = layoutUnknownLongFlag(in: rem3) {
            throw CLIError(message: String.localizedStringWithFormat(
                String(localized: "cli.layout.error.unknownFlagKnownFlags", defaultValue: "%@: unknown flag '%@'. Known flags: %@"),
                "layout export",
                unknown,
                "--workspace <id|ref|index>, --name <name>, --out <path>"
            ))
        }
        if let extra = rem3.first(where: { $0 != "--" }) {
            throw CLIError(message: String.localizedStringWithFormat(
                String(localized: "cli.layout.error.unexpectedArgument", defaultValue: "%@: unexpected argument '%@'"),
                "layout export",
                extra
            ))
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
                print(String.localizedStringWithFormat(
                    String(localized: "cli.layout.output.okPath", defaultValue: "OK %@"),
                    url.path
                ))
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
        if let unknown = layoutUnknownLongFlag(in: rem3) {
            throw CLIError(message: String.localizedStringWithFormat(
                String(localized: "cli.layout.error.unknownFlagKnownFlags", defaultValue: "%@: unknown flag '%@'. Known flags: %@"),
                "layout open",
                unknown,
                "--name <name>, --cwd <path>, --title <title>, --focus <true|false>"
            ))
        }
        let positional = layoutPositionalArguments(from: rem3)
        let rawName: String?
        if let nameOpt {
            if let extra = positional.first {
                throw CLIError(message: String.localizedStringWithFormat(
                    String(localized: "cli.layout.error.unexpectedArgument", defaultValue: "%@: unexpected argument '%@'"),
                    "layout open",
                    extra
                ))
            }
            rawName = nameOpt
        } else {
            guard positional.count <= 1 else {
                throw CLIError(message: String(localized: "cli.layout.error.openUsage", defaultValue: "Usage: cmux layout open <name> [--cwd <path>] [--title <title>] [--focus <true|false>]"))
            }
            rawName = positional.first
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

    private func layoutPresetDirectory() -> (url: URL, fromEnvironment: Bool) {
        let envOverride = ProcessInfo.processInfo.environment["CMUX_LAYOUT_PRESET_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fromEnvironment = envOverride?.isEmpty == false
        let path: String
        if let envOverride, fromEnvironment {
            path = resolvePath(envOverride)
        } else {
            path = NSString(string: "~/.config/cmux/layouts").expandingTildeInPath
        }
        return (URL(fileURLWithPath: path, isDirectory: true), fromEnvironment)
    }

    private func layoutPresetDirectoryURL() -> URL {
        layoutPresetDirectory().url
    }

    private func layoutPresetURL(name: String) -> URL {
        layoutPresetDirectoryURL()
            .appendingPathComponent(name, isDirectory: false)
            .appendingPathExtension("json")
    }

    private func layoutPresetName(_ raw: String?, commandName: String) throws -> String {
        guard let raw else {
            throw CLIError(message: String.localizedStringWithFormat(
                String(localized: "cli.layout.error.requiresPresetName", defaultValue: "%@ requires a preset name"),
                commandName
            ))
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CLIError(message: String.localizedStringWithFormat(
                String(localized: "cli.layout.error.requiresNonEmptyPresetName", defaultValue: "%@ requires a non-empty preset name"),
                commandName
            ))
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        guard trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw CLIError(message: String(localized: "cli.layout.error.invalidPresetNameCharacters", defaultValue: "Preset names may contain only letters, numbers, '.', '_', and '-'"))
        }
        guard !trimmed.hasPrefix(".") else {
            throw CLIError(message: String(localized: "cli.layout.error.invalidPresetNameHidden", defaultValue: "Preset names may not start with '.'"))
        }
        guard !trimmed.contains("..") else {
            throw CLIError(message: String(localized: "cli.layout.error.invalidPresetNameParentDirectory", defaultValue: "Preset names may not contain '..'"))
        }
        return trimmed
    }

    private func layoutPresetNameFromCandidate(
        _ raw: String?,
        fallbackName: String,
        commandName: String
    ) throws -> String {
        let normalized = CmuxWorkspacePresetName.normalized(
            raw,
            fallbackName: fallbackName
        )
        return try layoutPresetName(normalized, commandName: commandName)
    }

    private func layoutReadJSONObject(from url: URL) throws -> [String: Any] {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw CLIError(message: String.localizedStringWithFormat(
                String(localized: "cli.layout.error.readFailed", defaultValue: "Failed to read %@"),
                url.path
            ))
        }

        let sanitized: Data
        do {
            sanitized = try JSONCParser.preprocess(data: data)
        } catch {
            throw CLIError(message: String.localizedStringWithFormat(
                String(localized: "cli.layout.error.jsoncPreprocessFailed", defaultValue: "Failed to parse %@: JSONC preprocessing failed"),
                url.path
            ))
        }

        do {
            guard let object = try JSONSerialization.jsonObject(with: sanitized, options: []) as? [String: Any] else {
                throw CLIError(message: String.localizedStringWithFormat(
                    String(localized: "cli.layout.error.mustContainJSONObject", defaultValue: "%@ must contain a JSON object"),
                    url.path
                ))
            }
            return object
        } catch let error as CLIError {
            throw error
        } catch {
            throw CLIError(message: String.localizedStringWithFormat(
                String(localized: "cli.layout.error.parseFailed", defaultValue: "Failed to parse %@"),
                url.path
            ))
        }
    }

    private func layoutWriteJSONObject(_ object: [String: Any], to url: URL) throws {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw CLIError(message: String(localized: "cli.layout.error.invalidPresetJSONObject", defaultValue: "Layout preset is not a valid JSON object"))
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
            throw CLIError(message: String.localizedStringWithFormat(
                String(localized: "cli.layout.error.missingLayoutRoot", defaultValue: "%@: preset must contain workspace.layout or a layout root object"),
                commandName
            ))
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
            throw CLIError(message: String.localizedStringWithFormat(
                String(localized: "cli.layout.error.missingWorkspaceLayoutObject", defaultValue: "%@: preset workspace must include a layout object"),
                commandName
            ))
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
            throw CLIError(message: String(localized: "cli.layout.error.mustIncludeWorkspaceLayout", defaultValue: "Preset must include workspace.layout"))
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

    private func layoutDebugLogInvalidPresetListEntry(url: URL, error _: Error) {
        #if DEBUG
        FileHandle.standardError.write(Data("[cmux layout] invalid preset \(url.path)\n".utf8))
        #endif
    }

}
