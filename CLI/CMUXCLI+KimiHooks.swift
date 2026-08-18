import CMUXAgentLaunch
import Darwin
import Foundation

extension CMUXCLI {
    private static let kimiLifecycleHookTimeoutSeconds = 10
    private static let kimiFeedHookTimeoutSeconds = 120

    /// Config file name shared by every Kimi installation.
    static let kimiConfigFileName = "config.toml"

    /// Kimi Code CLI (current) reads `${KIMI_CODE_HOME:-~/.kimi-code}/config.toml`.
    /// Kimi CLI 1.49 and earlier read `${KIMI_SHARE_DIR:-~/.kimi}/config.toml`.
    /// Both installations are supported; the first entry wins ties.
    static let kimiCodeConfigDirectory = ".kimi-code"
    private static let kimiConfigDirectorySpecs: [KimiConfigDirectorySpec] = [
        KimiConfigDirectorySpec(
            environmentOverride: "KIMI_CODE_HOME",
            homeRelativeDirectory: kimiCodeConfigDirectory
        ),
        KimiConfigDirectorySpec(
            environmentOverride: "KIMI_SHARE_DIR",
            homeRelativeDirectory: ".kimi"
        ),
    ]

    /// `kimi doctor` only reports paths; it must never stall a hook install.
    private static let kimiDoctorProbeTimeoutSeconds: Double = 3

    private struct KimiConfigDirectorySpec {
        let environmentOverride: String
        let homeRelativeDirectory: String
    }

    /// Every Kimi config file cmux manages: the one the installed CLI reads,
    /// plus the well-known locations belonging to the other installation.
    struct KimiConfigLocations {
        let active: URL
        let secondary: [URL]

        var all: [URL] { [active] + secondary }
    }

    private struct KimiConfigEdit {
        let url: URL
        let oldContent: String
        let newContent: String
    }

    func kimiCodeHookEvents(def: AgentHookDef) -> [KimiCodeHookConfig.Event] {
        var events = def.events.map { event in
            KimiCodeHookConfig.Event(
                name: event.agentEvent,
                command: hookCommand(for: def, event: event),
                timeout: Self.kimiLifecycleHookTimeoutSeconds
            )
        }
        events.append(contentsOf: def.feedHookEvents.map { agentEvent in
            KimiCodeHookConfig.Event(
                name: agentEvent,
                command: feedHookCommand(for: def, agentEvent: agentEvent),
                timeout: Self.kimiFeedHookTimeoutSeconds
            )
        })
        return events
    }

    func installKimiHooks(_ def: AgentHookDef) throws {
        let fm = FileManager.default
        let locations = Self.kimiConfigLocations(for: def)
        let activeConfigURL = locations.active
        let configDir = activeConfigURL.deletingLastPathComponent().path
        let filePath = activeConfigURL.path
        let events = kimiCodeHookEvents(def: def)
        let skipConfirm = ProcessInfo.processInfo.arguments.contains("--yes")
            || ProcessInfo.processInfo.arguments.contains("-y")

        let configDirectoryFileError = String.localizedStringWithFormat(
            String(
                localized: "cli.hooks.error.configDirectoryIsFile",
                defaultValue: "cmux could not create the hooks directory: a file exists at %@. Remove or rename the conflicting file, then run `cmux hooks setup` again."
            ),
            configDir
        )
        var isConfigDirectory = ObjCBool(false)
        let configPathExists = fm.fileExists(atPath: configDir, isDirectory: &isConfigDirectory)
        if configPathExists, !isConfigDirectory.boolValue {
            throw CLIError(message: configDirectoryFileError)
        }

        let oldString = try readAgentHookConfig(filePath: filePath, displayName: def.displayName)
        let newString = KimiCodeHookConfig.installing(events: events, in: oldString)
        let activeEdit: KimiConfigEdit? = oldString == newString
            ? nil
            : KimiConfigEdit(url: activeConfigURL, oldContent: oldString, newContent: newString)
        if activeEdit == nil {
            print(String.localizedStringWithFormat(
                String(
                    localized: "cli.hooks.kimi.alreadyUpToDate",
                    defaultValue: "%@ hooks already up to date at %@"
                ),
                def.displayName,
                filePath
            ))
        }

        // A config the active CLI does not read still belongs to a Kimi install
        // the user may switch back to, so an existing cmux block there is
        // refreshed in place and a config without one is left untouched.
        var secondaryEdits: [KimiConfigEdit] = []
        var unrefreshedSecondaryURLs: [URL] = []
        for configURL in locations.secondary where fm.fileExists(atPath: configURL.path) {
            do {
                let oldSecondary = try readAgentHookConfig(
                    filePath: configURL.path,
                    displayName: def.displayName
                )
                guard KimiCodeHookConfig.containsCmuxBlock(in: oldSecondary) else { continue }
                let newSecondary = KimiCodeHookConfig.installing(events: events, in: oldSecondary)
                guard oldSecondary != newSecondary else { continue }
                secondaryEdits.append(KimiConfigEdit(
                    url: configURL,
                    oldContent: oldSecondary,
                    newContent: newSecondary
                ))
            } catch {
                unrefreshedSecondaryURLs.append(configURL)
            }
        }

        let edits = [activeEdit].compactMap { $0 } + secondaryEdits
        if !skipConfirm, !edits.isEmpty {
            for edit in edits {
                Self.printInstallPreview(
                    path: edit.url.path,
                    oldContent: edit.oldContent,
                    newContent: edit.newContent,
                    fallbackContent: edit.newContent
                )
            }
            print(String(
                localized: "cli.hooks.kimi.confirmProceed",
                defaultValue: "\nProceed? [y/N] "
            ), terminator: "")
            guard readLine()?.lowercased().hasPrefix("y") == true else {
                print(String(
                    localized: "cli.hooks.kimi.aborted",
                    defaultValue: "Aborted."
                ))
                return
            }
        }

        if let activeEdit {
            if !configPathExists {
                do {
                    try fm.createDirectory(atPath: configDir, withIntermediateDirectories: true)
                } catch {
                    throw CLIError(message: configDirectoryFileError)
                }
            }
            try activeEdit.newContent.write(to: activeEdit.url, atomically: true, encoding: .utf8)
            printKimiHooksInstalled(def: def, path: activeEdit.url.path)
        }

        for edit in secondaryEdits {
            do {
                try edit.newContent.write(to: edit.url, atomically: true, encoding: .utf8)
                printKimiHooksInstalled(def: def, path: edit.url.path)
            } catch {
                unrefreshedSecondaryURLs.append(edit.url)
            }
        }

        for configURL in unrefreshedSecondaryURLs {
            reportKimiSecondaryRefreshWarning(
                activeConfigURL: activeConfigURL,
                secondaryConfigURL: configURL
            )
        }
    }

    func uninstallKimiHooks(_ def: AgentHookDef) throws {
        let fm = FileManager.default
        let locations = Self.kimiConfigLocations(for: def)

        var foundConfig = false
        for (index, configURL) in locations.all.enumerated()
        where fm.fileExists(atPath: configURL.path) {
            foundConfig = true
            do {
                _ = try removeKimiHooks(at: configURL, def: def, reportNoChange: true)
            } catch {
                guard index > 0 else { throw error }
                reportKimiSecondaryUninstallWarning(secondaryConfigURL: configURL)
            }
        }
        guard !foundConfig else { return }

        print(String.localizedStringWithFormat(
            String(
                localized: "cli.hooks.kimi.noneFound",
                defaultValue: "No %@ found at %@"
            ),
            def.configFile,
            locations.active.path
        ))
    }

    private func removeKimiHooks(
        at configURL: URL,
        def: AgentHookDef,
        reportNoChange: Bool
    ) throws -> Bool {
        let oldString = try readAgentHookConfig(filePath: configURL.path, displayName: def.displayName)
        let newString = KimiCodeHookConfig.uninstalling(from: oldString)
        guard oldString != newString else {
            if reportNoChange {
                print(String.localizedStringWithFormat(
                    String(
                        localized: "cli.hooks.kimi.removedZero",
                        defaultValue: "Removed 0 cmux hook(s) from %@"
                    ),
                    configURL.path
                ))
            }
            return false
        }
        try newString.write(to: configURL, atomically: true, encoding: .utf8)
        print(String.localizedStringWithFormat(
            String(
                localized: "cli.hooks.kimi.removed",
                defaultValue: "Removed Kimi Code cmux hooks from %@"
            ),
            configURL.path
        ))
        return true
    }

    private func printKimiHooksInstalled(def: AgentHookDef, path: String) {
        print(String.localizedStringWithFormat(
            String(
                localized: "cli.hooks.kimi.installed",
                defaultValue: "%@ hooks installed at %@"
            ),
            def.displayName,
            path
        ))
    }

    private func reportKimiSecondaryRefreshWarning(
        activeConfigURL: URL,
        secondaryConfigURL: URL
    ) {
        let warning = String.localizedStringWithFormat(
            String(
                localized: "cli.hooks.kimi.secondaryRefreshWarning",
                defaultValue: "Warning: cmux hooks are installed at %@, but cmux could not refresh its existing hook block in %@. Check that path and re-run `cmux hooks setup kimi` to finish the update."
            ),
            activeConfigURL.path,
            secondaryConfigURL.path
        )
        cliWriteStderr(warning + "\n")
    }

    private func reportKimiSecondaryUninstallWarning(secondaryConfigURL: URL) {
        let warning = String.localizedStringWithFormat(
            String(
                localized: "cli.hooks.kimi.secondaryUninstallWarning",
                defaultValue: "Warning: cmux could not remove its hook block from %@. Check that path and re-run `cmux hooks uninstall kimi` to finish cleanup."
            ),
            secondaryConfigURL.path
        )
        cliWriteStderr(warning + "\n")
    }

    // MARK: Config discovery

    /// The Kimi config file cmux installs into, plus the other well-known Kimi
    /// configs it keeps consistent.
    ///
    /// The active file is the one the installed CLI reports through
    /// `kimi doctor`; when the binary cannot answer, it is the first well-known
    /// location that already exists, defaulting to the current Kimi Code CLI
    /// path. See https://github.com/manaflow-ai/cmux/issues/10255.
    static func kimiConfigLocations(for def: AgentHookDef) -> KimiConfigLocations {
        let candidates = kimiConfigDirectoryCandidates().map { directory in
            directory.appendingPathComponent(def.configFile, isDirectory: false)
        }
        let active = kimiDoctorReportedConfigURL(
            binaryName: def.binaryName,
            configFileName: def.configFile
        ) ?? URL(fileURLWithPath: def.resolvedConfigDir(), isDirectory: true)
            .appendingPathComponent(def.configFile, isDirectory: false)

        var seen: Set<URL> = [canonicalKimiConfigURL(active)]
        var secondary: [URL] = []
        for candidate in candidates where seen.insert(canonicalKimiConfigURL(candidate)).inserted {
            secondary.append(candidate)
        }
        return KimiConfigLocations(active: active, secondary: secondary)
    }

    /// The config directory used when the installed binary cannot report one.
    static func resolvedKimiConfigDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL {
        let candidates = kimiConfigDirectoryCandidates(environment: environment)
        if let configured = candidates.first(where: { directory in
            kimiRegularFileExists(
                directory.appendingPathComponent(kimiConfigFileName, isDirectory: false),
                fileManager: fileManager
            )
        }) {
            return configured
        }
        if let installed = candidates.first(where: {
            kimiDirectoryExists($0, fileManager: fileManager)
        }) {
            return installed
        }
        return candidates.first ?? kimiHomeURL(environment: environment)
            .appendingPathComponent(kimiCodeConfigDirectory, isDirectory: true)
    }

    private static func kimiConfigDirectoryCandidates(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [URL] {
        let home = kimiHomeURL(environment: environment)
        return kimiConfigDirectorySpecs.map { spec in
            if let override = nonEmptyKimiEnvironmentValue(
                environment[spec.environmentOverride]
            ) {
                return URL(
                    fileURLWithPath: NSString(string: override).expandingTildeInPath,
                    isDirectory: true
                )
            }
            return home.appendingPathComponent(spec.homeRelativeDirectory, isDirectory: true)
        }
    }

    /// The absolute `config.toml` path `kimi doctor` reports, when it reports a
    /// usable one. A binary that is missing, does not know the subcommand, or
    /// prints no path leaves the well-known locations in charge.
    private static func kimiDoctorReportedConfigURL(
        binaryName: String,
        configFileName: String,
        fileManager: FileManager = .default
    ) -> URL? {
        guard let output = runKimiDoctor(binaryName: binaryName),
              let reported = kimiConfigURL(inDoctorOutput: output, configFileName: configFileName),
              kimiDirectoryExists(reported.deletingLastPathComponent(), fileManager: fileManager)
        else {
            return nil
        }
        return reported
    }

    static func kimiConfigURL(inDoctorOutput output: String, configFileName: String) -> URL? {
        let trimmed = CharacterSet(charactersIn: "\"'`,;:()[]{}<>")
        for token in output.split(whereSeparator: { $0.isWhitespace }) {
            let candidate = String(token).trimmingCharacters(in: trimmed)
            guard !candidate.isEmpty else { continue }
            let expanded = NSString(string: candidate).expandingTildeInPath
            guard expanded.hasPrefix("/") else { continue }
            let url = URL(fileURLWithPath: expanded, isDirectory: false).standardizedFileURL
            guard url.lastPathComponent == configFileName else { continue }
            return url
        }
        return nil
    }

    private static func runKimiDoctor(binaryName: String) -> String? {
        let fm = FileManager.default
        let outputURL = fm.temporaryDirectory
            .appendingPathComponent("cmux-kimi-doctor-\(UUID().uuidString)", isDirectory: false)
        guard fm.createFile(atPath: outputURL.path, contents: nil) else { return nil }
        defer { try? fm.removeItem(at: outputURL) }
        guard let outputHandle = try? FileHandle(forWritingTo: outputURL) else { return nil }
        defer { try? outputHandle.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [binaryName, "doctor"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputHandle
        process.standardError = outputHandle
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try cliRunProcess(process)
        } catch {
            return nil
        }
        if exited.wait(timeout: .now() + kimiDoctorProbeTimeoutSeconds) == .timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 1)
            }
        }
        return try? String(contentsOf: outputURL, encoding: .utf8)
    }

    private static func kimiHomeURL(environment: [String: String]) -> URL {
        let home = nonEmptyKimiEnvironmentValue(environment["HOME"]) ?? NSHomeDirectory()
        return URL(fileURLWithPath: home, isDirectory: true)
    }

    private static func nonEmptyKimiEnvironmentValue(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func kimiDirectoryExists(_ url: URL, fileManager: FileManager) -> Bool {
        var isDirectory = ObjCBool(false)
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private static func kimiRegularFileExists(_ url: URL, fileManager: FileManager) -> Bool {
        var isDirectory = ObjCBool(false)
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
    }

    private static func canonicalKimiConfigURL(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }
}
