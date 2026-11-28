import CMUXAgentLaunch
import Darwin
import Foundation

extension CMUXCLI {
    private static let kimiLifecycleHookTimeoutSeconds = 10
    private static let kimiFeedHookTimeoutSeconds = 120

    /// `kimi doctor` only reports paths; it must never stall a hook install.
    private static let kimiDoctorProbeTimeoutSeconds: Double = 3

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
        let targets: [(url: URL, isActive: Bool)] =
            [(url: locations.active, isActive: true)]
            + locations.secondary.map { (url: $0, isActive: false) }

        var foundConfig = false
        for target in targets where fm.fileExists(atPath: target.url.path) {
            foundConfig = true
            do {
                _ = try removeKimiHooks(at: target.url, def: def, reportNoChange: true)
            } catch {
                guard !target.isActive else { throw error }
                reportKimiSecondaryUninstallWarning(secondaryConfigURL: target.url)
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

    /// The config directory used when the installed binary reports none.
    static func resolvedKimiConfigDirectory() -> URL {
        KimiConfigLocationResolver(environment: ProcessInfo.processInfo.environment)
            .fallbackConfigDirectory()
    }

    /// The Kimi config files cmux manages, resolved from the installed binary.
    static func kimiConfigLocations(for def: AgentHookDef) -> KimiConfigLocationResolver.Locations {
        let resolver = KimiConfigLocationResolver(
            environment: ProcessInfo.processInfo.environment,
            configFileName: def.configFile
        )
        let reported = runKimiDoctor(binaryName: def.binaryName).flatMap { output in
            resolver.reportedConfigURL(inDoctorOutput: output)
        }
        return resolver.locations(reportedConfigURL: reported)
    }

    /// Runs `<binary> doctor` and returns its combined output.
    ///
    /// The probe writes to a temporary file rather than a pipe so a chatty
    /// binary cannot deadlock the wait, and it is bounded so a hung binary
    /// cannot stall `cmux hooks setup`. A binary that is missing or does not
    /// know the subcommand simply produces no usable path.
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
}
