import Foundation

extension CMUXCLI {
    static func resolvedCampfireAgentDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let agentRoot = nonEmptyCampfireEnvironmentValue("CAMPFIRE_CODING_AGENT_DIR", in: environment) {
            return URL(
                fileURLWithPath: NSString(string: agentRoot).expandingTildeInPath,
                isDirectory: true
            )
        }

        let home = nonEmptyCampfireEnvironmentValue("HOME", in: environment) ?? NSHomeDirectory()
        return URL(fileURLWithPath: NSString(string: home).expandingTildeInPath, isDirectory: true)
            .appendingPathComponent(".campfire", isDirectory: true)
            .appendingPathComponent("agent", isDirectory: true)
    }

    private static func nonEmptyCampfireEnvironmentValue(_ name: String, in environment: [String: String]) -> String? {
        let trimmed = environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func campfireExtensionURL() -> URL {
        return Self.resolvedCampfireAgentDirectory()
            .appendingPathComponent("extensions", isDirectory: true)
            .appendingPathComponent(Self.campfireExtensionFilename, isDirectory: false)
    }

    private func existingCampfireExtensionContents(at url: URL, fileManager: FileManager = .default) throws -> String {
        guard fileManager.fileExists(atPath: url.path) else { return "" }
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            let message = String.localizedStringWithFormat(
                String(
                    localized: "cli.hooks.campfire.error.readFailed",
                    defaultValue: "Failed to read %@"
                ),
                url.path
            )
            throw CLIError(message: message)
        }
    }

    func installCampfireExtensionHooks(_ _: AgentHookDef) throws {
        let extensionURL = campfireExtensionURL()
        let fileManager = FileManager.default
        let skipConfirm = ProcessInfo.processInfo.arguments.contains("--yes")
            || ProcessInfo.processInfo.arguments.contains("-y")
        let existing = try existingCampfireExtensionContents(at: extensionURL, fileManager: fileManager)
        if existing == Self.campfireExtensionSource {
            print(String.localizedStringWithFormat(
                String(
                    localized: "cli.hooks.campfire.alreadyUpToDate",
                    defaultValue: "Campfire hooks already up to date at %@"
                ),
                extensionURL.path
            ))
            return
        }
        if !existing.isEmpty, !existing.contains(Self.campfireExtensionMarker) {
            throw CLIError(message: String.localizedStringWithFormat(
                String(
                    localized: "cli.hooks.campfire.error.notCmuxExtension",
                    defaultValue: "%@ exists and is not a cmux extension; leaving it alone"
                ),
                extensionURL.path
            ))
        }
        if !skipConfirm {
            Self.printInstallPreview(
                path: extensionURL.path,
                oldContent: existing,
                newContent: Self.campfireExtensionSource,
                fallbackContent: Self.campfireExtensionSource
            )
            print(String(localized: "cli.hooks.campfire.confirmProceed", defaultValue: "\nProceed? [y/N] "), terminator: "")
            guard readLine()?.lowercased().hasPrefix("y") == true else {
                print(String(localized: "cli.hooks.campfire.aborted", defaultValue: "Aborted."))
                return
            }
        }
        try fileManager.createDirectory(
            at: extensionURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Self.campfireExtensionSource.write(to: extensionURL, atomically: true, encoding: .utf8)
        print(String.localizedStringWithFormat(
            String(
                localized: "cli.hooks.campfire.installed",
                defaultValue: "Campfire hooks installed at %@"
            ),
            extensionURL.path
        ))
    }

    func uninstallCampfireExtensionHooks(_ _: AgentHookDef) throws {
        let extensionURL = campfireExtensionURL()
        let fm = FileManager.default
        guard fm.fileExists(atPath: extensionURL.path) else {
            print(String.localizedStringWithFormat(
                String(
                    localized: "cli.hooks.campfire.noneFound",
                    defaultValue: "No Campfire cmux extension found at %@"
                ),
                extensionURL.path
            ))
            return
        }
        let existing = try existingCampfireExtensionContents(at: extensionURL, fileManager: fm)
        guard existing.contains(Self.campfireExtensionMarker) else {
            print(String.localizedStringWithFormat(
                String(
                    localized: "cli.hooks.campfire.refuseRemoveMissingMarker",
                    defaultValue: "Refusing to remove %@: missing cmux marker"
                ),
                extensionURL.path
            ))
            return
        }
        try fm.removeItem(at: extensionURL)
        print(String.localizedStringWithFormat(
            String(
                localized: "cli.hooks.campfire.removed",
                defaultValue: "Removed Campfire cmux extension from %@"
            ),
            extensionURL.path
        ))
    }
}
