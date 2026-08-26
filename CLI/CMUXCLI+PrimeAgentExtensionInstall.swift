import Foundation

extension CMUXCLI {
    func primeAgentExtensionURL(for def: AgentHookDef) -> URL {
        URL(fileURLWithPath: def.resolvedConfigDir(), isDirectory: true)
            .appendingPathComponent("extensions", isDirectory: true)
            .appendingPathComponent(Self.primeAgentExtensionFilename, isDirectory: false)
    }

    func existingPrimeAgentExtensionContents(at url: URL) throws -> String {
        guard FileManager.default.fileExists(atPath: url.path) else { return "" }
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            let message = String.localizedStringWithFormat(
                String(localized: "cli.hooks.primeAgent.error.readFailed", defaultValue: "Failed to read %@"),
                url.path
            )
            throw CLIError(message: "\(message): \(String(describing: error))")
        }
    }

    func installPrimeAgentExtensionHooks(_ def: AgentHookDef) throws {
        let extensionURL = primeAgentExtensionURL(for: def)
        let fileManager = FileManager.default
        let existing = try existingPrimeAgentExtensionContents(at: extensionURL)
        if existing == Self.primeAgentExtensionSource {
            print(String.localizedStringWithFormat(
                String(localized: "cli.hooks.primeAgent.alreadyUpToDate", defaultValue: "Prime Agent hooks already up to date at %@"),
                extensionURL.path
            ))
            return
        }
        if !existing.isEmpty, !existing.contains(Self.primeAgentExtensionMarker) {
            throw CLIError(message: String.localizedStringWithFormat(
                String(localized: "cli.hooks.primeAgent.error.notCmuxExtension", defaultValue: "%@ exists and is not a cmux extension; leaving it alone"),
                extensionURL.path
            ))
        }
        let skipConfirm = ProcessInfo.processInfo.arguments.contains("--yes")
            || ProcessInfo.processInfo.arguments.contains("-y")
        if !skipConfirm {
            Self.printInstallPreview(
                path: extensionURL.path,
                oldContent: existing,
                newContent: Self.primeAgentExtensionSource,
                fallbackContent: Self.primeAgentExtensionSource
            )
            print(String(localized: "cli.hooks.primeAgent.confirmProceed", defaultValue: "\nProceed? [y/N] "), terminator: "")
            guard readLine()?.lowercased().hasPrefix("y") == true else {
                print(String(localized: "cli.hooks.primeAgent.aborted", defaultValue: "Aborted."))
                return
            }
        }
        try fileManager.createDirectory(
            at: extensionURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Self.primeAgentExtensionSource.write(to: extensionURL, atomically: true, encoding: .utf8)
        print(String.localizedStringWithFormat(
            String(localized: "cli.hooks.primeAgent.installed", defaultValue: "Prime Agent hooks installed at %@"),
            extensionURL.path
        ))
    }

    func uninstallPrimeAgentExtensionHooks(_ def: AgentHookDef) throws {
        let extensionURL = primeAgentExtensionURL(for: def)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: extensionURL.path) else {
            print(String.localizedStringWithFormat(
                String(localized: "cli.hooks.primeAgent.noneFound", defaultValue: "No Prime Agent cmux extension found at %@"),
                extensionURL.path
            ))
            return
        }
        let existing = try existingPrimeAgentExtensionContents(at: extensionURL)
        guard existing.contains(Self.primeAgentExtensionMarker) else {
            print(String.localizedStringWithFormat(
                String(localized: "cli.hooks.primeAgent.refuseRemoveMissingMarker", defaultValue: "Refusing to remove %@: missing cmux marker"),
                extensionURL.path
            ))
            return
        }
        try fileManager.removeItem(at: extensionURL)
        print(String.localizedStringWithFormat(
            String(localized: "cli.hooks.primeAgent.removed", defaultValue: "Removed Prime Agent cmux extension from %@"),
            extensionURL.path
        ))
    }
}
