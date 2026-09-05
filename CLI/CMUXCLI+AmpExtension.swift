import Foundation

extension CMUXCLI {
    static let ampExtensionMarker = "cmux-amp-session-extension-marker"
    static let ampExtensionFilename = "cmux-session.ts"
    static let ampExtensionSource =
        ampExtensionPrelude
        + ampExtensionReconciliation
        + ampExtensionHandlers

    /// Resolves the private semantic status values emitted by the Amp plugin
    /// in the host locale before forwarding them to the sidebar socket.
    static func localizedAmpStatusArguments(_ arguments: [String]) -> [String] {
        guard arguments.count >= 2,
              arguments[0] == "amp" else {
            return arguments
        }
        let value = arguments[1]
        let localized: String
        switch value {
        case "__cmux_amp_status_idle":
            localized = String(localized: "agent.generic.notification.status.idle", defaultValue: "Idle")
        case "__cmux_amp_status_thinking":
            localized = String(localized: "agent.generic.status.running", defaultValue: "Running")
        case "__cmux_amp_status_needs_input":
            localized = String(localized: "feed.status.needsInput", defaultValue: "Needs input")
        case "__cmux_amp_status_done":
            localized = String(localized: "sidebar.status.done", defaultValue: "Done")
        case "__cmux_amp_status_error":
            localized = String(localized: "agent.generic.notification.subtitle.error", defaultValue: "Error")
        case "__cmux_amp_status_interrupted":
            localized = String(localized: "agent.generic.notification.status.interrupted", defaultValue: "Interrupted")
        default:
            return arguments
        }
        var result = arguments
        result[1] = localized
        return result
    }

    private func ampExtensionURL(for def: AgentHookDef) -> URL {
        URL(fileURLWithPath: def.resolvedConfigDir(), isDirectory: true)
            .appendingPathComponent("plugins", isDirectory: true)
            .appendingPathComponent(Self.ampExtensionFilename, isDirectory: false)
    }

    func installAmpExtensionHooks(_ def: AgentHookDef) throws {
        let extensionURL = ampExtensionURL(for: def)
        let skipConfirm = ProcessInfo.processInfo.arguments.contains("--yes")
            || ProcessInfo.processInfo.arguments.contains("-y")
        let existing = (try? String(contentsOf: extensionURL, encoding: .utf8)) ?? ""
        if existing == Self.ampExtensionSource {
            print(String.localizedStringWithFormat(
                String(
                    localized: "cli.hooks.amp.alreadyUpToDate",
                    defaultValue: "Amp hooks already up to date at %@"
                ),
                extensionURL.path
            ))
            return
        }
        if !existing.isEmpty, !existing.contains(Self.ampExtensionMarker) {
            throw CLIError(message: "\(extensionURL.path) exists and is not a cmux plugin; leaving it alone")
        }
        if !skipConfirm {
            Self.printInstallPreview(
                path: extensionURL.path,
                oldContent: existing,
                newContent: Self.ampExtensionSource,
                fallbackContent: Self.ampExtensionSource
            )
            print("\nProceed? [y/N] ", terminator: "")
            guard readLine()?.lowercased().hasPrefix("y") == true else {
                print("Aborted.")
                return
            }
        }
        try FileManager.default.createDirectory(
            at: extensionURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Self.ampExtensionSource.write(to: extensionURL, atomically: true, encoding: .utf8)
        print("Amp hooks installed at \(extensionURL.path)")
    }

    func uninstallAmpExtensionHooks(_ def: AgentHookDef) throws {
        let extensionURL = ampExtensionURL(for: def)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: extensionURL.path) else {
            print("No Amp cmux plugin found at \(extensionURL.path)")
            return
        }
        let existing = (try? String(contentsOf: extensionURL, encoding: .utf8)) ?? ""
        guard existing.contains(Self.ampExtensionMarker) else {
            print("Refusing to remove \(extensionURL.path): missing cmux marker")
            return
        }
        try fileManager.removeItem(at: extensionURL)
        print("Removed Amp cmux plugin from \(extensionURL.path)")
    }
}
