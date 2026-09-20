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

    /// Only an absent file is installable. Read failures and symbolic links must
    /// never become empty content that the installer can replace.
    private static func ampExtensionContents(at url: URL) throws -> String? {
        let attributes: [FileAttributeKey: Any]
        do {
            // attributesOfItem uses lstat semantics: inspect the path itself,
            // without following a link to a possibly managed plugin elsewhere.
            attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch let error as CocoaError
            where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return nil
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw CLIError(message: "\(url.path) is not a regular file; leaving it alone")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    static func ampExtensionInstallState(existing: String?) -> String {
        guard let existing else { return "missing" }
        if existing == ampExtensionSource { return "installed" }
        if existing.contains(ampExtensionMarker) { return "stale" }
        return "conflict"
    }

    private func printAmpExtensionStatusJSON(path: String, existing: String?) throws {
        let payload: [String: String] = [
            "integration": "amp",
            "state": Self.ampExtensionInstallState(existing: existing),
            "path": path,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        guard let json = String(data: data, encoding: .utf8) else {
            throw CLIError(message: "Failed to encode Amp hook installation status")
        }
        print(json)
    }

    func installAmpExtensionHooks(_ def: AgentHookDef) throws {
        let extensionURL = ampExtensionURL(for: def)
        let skipConfirm = ProcessInfo.processInfo.arguments.contains("--yes")
            || ProcessInfo.processInfo.arguments.contains("-y")
        let existing = try Self.ampExtensionContents(at: extensionURL)
        if ProcessInfo.processInfo.arguments.contains("--status-json") {
            try printAmpExtensionStatusJSON(path: extensionURL.path, existing: existing)
            return
        }
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
        if let existing, !existing.contains(Self.ampExtensionMarker) {
            throw CLIError(message: "\(extensionURL.path) exists and is not a cmux plugin; leaving it alone")
        }
        if !skipConfirm {
            Self.printInstallPreview(
                path: extensionURL.path,
                oldContent: existing ?? "",
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
        guard let existing = try Self.ampExtensionContents(at: extensionURL) else {
            print("No Amp cmux plugin found at \(extensionURL.path)")
            return
        }
        guard existing.contains(Self.ampExtensionMarker) else {
            print("Refusing to remove \(extensionURL.path): missing cmux marker")
            return
        }
        try fileManager.removeItem(at: extensionURL)
        print("Removed Amp cmux plugin from \(extensionURL.path)")
    }
}
