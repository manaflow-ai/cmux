import Foundation
import CmuxFoundation
import CmuxTerminalImport
import Darwin

/// `cmux import`: bring fonts, colors and terminal behavior over from another terminal.
///
/// Parsing and mapping live in the CmuxTerminalImport package; this file only
/// resolves paths, prints the plan, asks for confirmation and writes cmux's own
/// Ghostty config and theme files. The source terminal's files and the user's
/// `~/.config/ghostty/config` are never written.
extension CMUXCLI {
    func runImport(
        commandArgs: [String],
        jsonOutput: Bool,
        socketPath: String,
        explicitPassword: String?
    ) throws {
        let dryRun = hasFlag(commandArgs, name: "--dry-run")
        let assumeYes = hasFlag(commandArgs, name: "--yes") || hasFlag(commandArgs, name: "-y")
        let path = optionValue(commandArgs, name: "--path")
        let positional = firstPositionalArgument(commandArgs, valueOptions: ["--path"])
        if let unknown = commandArgs.first(where: {
            $0.hasPrefix("-") && !["--dry-run", "--yes", "-y", "--path"].contains($0) && !$0.hasPrefix("--path=")
        }) {
            throw CLIError(message: "import: unknown flag '\(unknown)'. Run 'cmux import --help'.")
        }

        let importer = terminalImporter()
        let targetBundleIdentifier = themeTargetBundleIdentifier(socketPath: socketPath)

        guard let sourceName = positional else {
            let detected = importer.detect()
            if jsonOutput {
                print(jsonString(["terminals": detected.map(terminalImportDetectionPayload)]))
                return
            }
            printDetectedTerminals(detected)
            let importable = detected.filter { $0.source != .ghostty }
            guard !importable.isEmpty, isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1 else { return }
            print("")
            print("Import which? [1-\(importable.count), Enter to cancel] ", terminator: "")
            guard let answer = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let choice = Int(answer), (1...importable.count).contains(choice) else {
                print("Nothing imported.")
                return
            }
            print("")
            try runImport(
                source: importable[choice - 1].source,
                path: importable[choice - 1].configURL,
                importer: importer,
                dryRun: dryRun,
                assumeYes: assumeYes,
                jsonOutput: false,
                socketPath: socketPath,
                targetBundleIdentifier: targetBundleIdentifier,
                explicitPassword: explicitPassword
            )
            return
        }

        if jsonOutput, !dryRun, !assumeYes {
            throw CLIError(message: "import: --json writes only with --yes. Add --dry-run to preview the plan instead.")
        }
        guard let source = TerminalImportSource(argument: sourceName) else {
            let names = TerminalImportSource.allCases.map(\.rawValue).joined(separator: ", ")
            throw CLIError(message: "import: unknown terminal '\(sourceName)'. Supported: \(names).")
        }
        try runImport(
            source: source,
            path: path.map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) },
            importer: importer,
            dryRun: dryRun,
            assumeYes: assumeYes,
            jsonOutput: jsonOutput,
            socketPath: socketPath,
            targetBundleIdentifier: targetBundleIdentifier,
            explicitPassword: explicitPassword
        )
    }

    private func runImport(
        source: TerminalImportSource,
        path: URL?,
        importer: TerminalImporter,
        dryRun: Bool,
        assumeYes: Bool,
        jsonOutput: Bool,
        socketPath: String,
        targetBundleIdentifier: String,
        explicitPassword: String?
    ) throws {
        let settings: ImportedTerminalSettings
        do {
            settings = try importer.load(source, path: path)
        } catch let error as TerminalImportError {
            if error == .ghosttyAlreadyLoaded {
                if jsonOutput {
                    let payload: [String: Any] = [
                        "ok": true,
                        "source": source.rawValue,
                        "written": false,
                        "notes": [error.message],
                    ]
                    print(jsonString(payload))
                } else {
                    print(error.message)
                }
                return
            }
            throw CLIError(message: "import: \(error.message)")
        }

        let configURL = try cmuxThemeOverrideConfigURL(targetBundleIdentifier: targetBundleIdentifier)
        let themeDirectory = configURL.deletingLastPathComponent().appendingPathComponent("themes", isDirectory: true)
        let plan = GhosttyImportMapper(fontResolver: CoreTextFontFamilyResolver())
            .plan(for: settings, themeDirectory: themeDirectory)
        let themeFile = CmuxManagedThemeConfigFile(url: configURL)
        let currentContents = try themeFile.readContents() ?? ""
        let patch = GhosttyConfigDiffer().diff(plan.settings, against: currentContents)
        let currentTheme = try themeFile.managedThemeValue()

        if jsonOutput {
            let shouldWrite = !dryRun && !plan.isEmpty
            if shouldWrite {
                try writeImportPlan(plan, patch: patch, configURL: configURL)
                _ = reloadThemesIfPossible(
                    socketPath: socketPath,
                    targetBundleIdentifier: targetBundleIdentifier,
                    explicitPassword: explicitPassword
                )
            }
            let payload: [String: Any] = [
                "ok": true,
                "source": source.rawValue,
                "profile": settings.profileName ?? NSNull(),
                "dry_run": dryRun,
                "written": shouldWrite,
                "config_path": configURL.path,
                "theme_files": plan.themeFiles.map(\.url.path),
                "theme": ["old": currentTheme ?? NSNull(), "new": plan.themeValue ?? NSNull()] as [String: Any],
                "changes": patch.changes.map { change -> [String: Any] in
                    ["key": change.key, "old": change.oldValues, "new": change.newValues]
                },
                "notes": plan.notes,
            ]
            print(jsonString(payload))
            return
        }

        let profile = settings.profileName.map { " (\($0))" } ?? ""
        print("Import from \(source.displayName)\(profile)")
        if plan.isEmpty {
            print("")
            print("Nothing to import: no fonts, colors or terminal settings were found.")
            printImportNotes(plan.notes)
            return
        }

        if !plan.themeFiles.isEmpty {
            print("")
            print("Theme files:")
            for file in plan.themeFiles {
                let exists = FileManager.default.fileExists(atPath: file.url.path)
                let colorCount = file.contents.split(separator: "\n").count - 1
                print("  \(exists ? "replace" : "create ") \(abbreviatedImportPath(file.url)) (\(colorCount) colors)")
            }
        }
        print("")
        print("Changes to \(abbreviatedImportPath(configURL)):")
        if let themeValue = plan.themeValue {
            if currentTheme == themeValue {
                print("  theme = \(themeValue)")
            } else {
                if let currentTheme { print("- theme = \(currentTheme)") }
                print("+ theme = \(themeValue)")
            }
        }
        for line in patch.diffLines {
            print(line)
        }
        printImportNotes(plan.notes)
        print("")
        print("Your ~/.config/ghostty/config and \(source.displayName)'s own settings are not changed.")

        if dryRun {
            print("Dry run: nothing was written.")
            return
        }
        if !assumeYes {
            // Without a terminal to confirm in, writing takes an explicit --yes.
            guard isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1 else {
                throw CLIError(message: "import: not a terminal, so nothing was written. Re-run with --yes to write these changes.")
            }
            print("Write these changes? [y/N] ", terminator: "")
            guard readLine()?.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("y") == true else {
                print("Nothing written.")
                return
            }
        }

        try writeImportPlan(plan, patch: patch, configURL: configURL)
        _ = reloadThemesIfPossible(
            socketPath: socketPath,
            targetBundleIdentifier: targetBundleIdentifier,
            explicitPassword: explicitPassword
        )
        print("Imported and reloaded cmux. Padding and scrollback apply to new terminals. Lines marked - above were the previous values.")
    }

    /// Writes theme files, then each setting through cmux's shared config
    /// writer (which keeps a list key's lines together where the key first
    /// appeared), then selects the theme through the managed theme block.
    private func writeImportPlan(
        _ plan: GhosttyImportPlan,
        patch: GhosttyConfigDiff,
        configURL: URL
    ) throws {
        let fileManager = FileManager.default
        for file in plan.themeFiles {
            try fileManager.createDirectory(
                at: file.url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: nil
            )
            try file.contents.write(to: file.url, atomically: true, encoding: .utf8)
        }
        let editor = CmuxGhosttyConfigSettingEditor()
        for setting in plan.settings {
            guard let change = patch.changes.first(where: { $0.key == setting.key }), !change.isUnchanged else {
                continue
            }
            try editor.writeSetting(key: setting.key, values: setting.values, to: configURL, fileManager: fileManager)
        }
        if let themeValue = plan.themeValue {
            try CmuxManagedThemeConfigFile(url: configURL).write(rawThemeValue: themeValue)
        }
    }

    private func terminalImporter() -> TerminalImporter {
        let environment = ProcessInfo.processInfo.environment
        let home = environment["HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        return TerminalImporter(
            homeDirectory: home,
            environment: environment,
            preferences: SystemTerminalPreferencesReader(homeDirectory: home),
            files: DiskTerminalConfigFileReader()
        )
    }

    private func printDetectedTerminals(_ detected: [DetectedTerminal]) {
        guard !detected.isEmpty else {
            let names = TerminalImportSource.allCases
                .filter { $0 != .ghostty }
                .map(\.displayName)
                .joined(separator: ", ")
            print("No settings from other terminals found. cmux can import from \(names).")
            return
        }
        print("Terminals with settings on this Mac:")
        var number = 0
        for terminal in detected {
            let name = terminal.source.rawValue.padding(toLength: 9, withPad: " ", startingAt: 0)
            if terminal.source == .ghostty {
                print("   -  \(name) \(terminal.detail): already loaded by cmux, nothing to import")
            } else {
                number += 1
                print("  \(String(format: "%2d", number)). \(name) \(terminal.detail)")
            }
        }
        if number > 0 {
            print("")
            print("Preview with: cmux import <terminal> --dry-run")
        }
    }

    private func printImportNotes(_ notes: [String]) {
        guard !notes.isEmpty else { return }
        print("")
        print("Not imported or approximated:")
        for note in notes {
            print("  * \(note)")
        }
    }

    private func terminalImportDetectionPayload(_ terminal: DetectedTerminal) -> [String: Any] {
        [
            "source": terminal.source.rawValue,
            "name": terminal.source.displayName,
            "detail": terminal.detail,
            "config_path": terminal.configURL?.path ?? NSNull(),
            "importable": terminal.source != .ghostty,
        ]
    }

    private func abbreviatedImportPath(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return url.path.hasPrefix(home + "/") ? "~" + url.path.dropFirst(home.count) : url.path
    }
}
