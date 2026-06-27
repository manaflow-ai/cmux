import Foundation

extension CMUXCLI {
    private static let piExtensionMarker = "cmux-pi-session-extension-marker"
    private static let piExtensionFilename = "cmux-session.ts"

    private func piExtensionURL(for def: AgentHookDef) -> URL {
        URL(fileURLWithPath: def.resolvedConfigDir(), isDirectory: true)
            .appendingPathComponent("extensions", isDirectory: true)
            .appendingPathComponent(Self.piExtensionFilename, isDirectory: false)
    }

    private func existingPiExtensionContents(at url: URL, fileManager: FileManager = .default) throws -> String {
        guard fileManager.fileExists(atPath: url.path) else { return "" }
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            let message = String.localizedStringWithFormat(
                String(
                    localized: "cli.hooks.pi.error.readFailed",
                    defaultValue: "Failed to read %@"
                ),
                url.path
            )
            throw CLIError(message: message)
        }
    }

    func installPiExtensionHooks(_ def: AgentHookDef) throws {
        let extensionURL = piExtensionURL(for: def)
        let fileManager = FileManager.default
        let skipConfirm = ProcessInfo.processInfo.arguments.contains("--yes")
            || ProcessInfo.processInfo.arguments.contains("-y")
        let existing = try existingPiExtensionContents(at: extensionURL, fileManager: fileManager)
        if existing == Self.piExtensionSource {
            print(String.localizedStringWithFormat(
                String(
                    localized: "cli.hooks.pi.alreadyUpToDate",
                    defaultValue: "Pi hooks already up to date at %@"
                ),
                extensionURL.path
            ))
            return
        }
        if !existing.isEmpty, !existing.contains(Self.piExtensionMarker) {
            throw CLIError(message: String.localizedStringWithFormat(
                String(
                    localized: "cli.hooks.pi.error.notCmuxExtension",
                    defaultValue: "%@ exists and is not a cmux extension; leaving it alone"
                ),
                extensionURL.path
            ))
        }
        if !skipConfirm {
            Self.printInstallPreview(
                path: extensionURL.path,
                oldContent: existing,
                newContent: Self.piExtensionSource,
                fallbackContent: Self.piExtensionSource
            )
            print(String(localized: "cli.hooks.pi.confirmProceed", defaultValue: "\nProceed? [y/N] "), terminator: "")
            guard readLine()?.lowercased().hasPrefix("y") == true else {
                print(String(localized: "cli.hooks.pi.aborted", defaultValue: "Aborted."))
                return
            }
        }
        try fileManager.createDirectory(
            at: extensionURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Self.piExtensionSource.write(to: extensionURL, atomically: true, encoding: .utf8)
        print(String.localizedStringWithFormat(
            String(
                localized: "cli.hooks.pi.installed",
                defaultValue: "Pi hooks installed at %@"
            ),
            extensionURL.path
        ))
    }

    func uninstallPiExtensionHooks(_ def: AgentHookDef) throws {
        let extensionURL = piExtensionURL(for: def)
        let fm = FileManager.default
        guard fm.fileExists(atPath: extensionURL.path) else {
            print(String.localizedStringWithFormat(
                String(
                    localized: "cli.hooks.pi.noneFound",
                    defaultValue: "No Pi cmux extension found at %@"
                ),
                extensionURL.path
            ))
            return
        }
        let existing = try existingPiExtensionContents(at: extensionURL, fileManager: fm)
        guard existing.contains(Self.piExtensionMarker) else {
            print(String.localizedStringWithFormat(
                String(
                    localized: "cli.hooks.pi.refuseRemoveMissingMarker",
                    defaultValue: "Refusing to remove %@: missing cmux marker"
                ),
                extensionURL.path
            ))
            return
        }
        try fm.removeItem(at: extensionURL)
        print(String.localizedStringWithFormat(
            String(
                localized: "cli.hooks.pi.removed",
                defaultValue: "Removed Pi cmux extension from %@"
            ),
            extensionURL.path
        ))
    }
}
