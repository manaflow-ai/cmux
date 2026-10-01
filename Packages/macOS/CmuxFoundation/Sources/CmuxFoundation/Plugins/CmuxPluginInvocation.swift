import Foundation

/// Where a plugin command runs and what it is told about cmux.
public struct CmuxPluginInvocationContext: Equatable, Sendable {
    public var socketPath: String?
    /// The bundled `cmux` CLI; its directory is put first on `PATH`.
    public var cliPath: String?
    public var workspaceID: String?
    public var surfaceID: String?
    public var actionID: String?

    public init(
        socketPath: String? = nil,
        cliPath: String? = nil,
        workspaceID: String? = nil,
        surfaceID: String? = nil,
        actionID: String? = nil
    ) {
        self.socketPath = socketPath
        self.cliPath = cliPath
        self.workspaceID = workspaceID
        self.surfaceID = surfaceID
        self.actionID = actionID
    }
}

/// Builds the environment and `/bin/sh -c` script for a plugin argv.
///
/// The automation engine already runs `/bin/sh -c` commands in an owned,
/// time-limited process group, so plugin actions and event hooks reuse it.
/// The argv is single-quoted element by element: the plugin's arguments
/// never pass through shell expansion.
public struct CmuxPluginInvocation: Equatable, Sendable {
    public let plugin: CmuxInstalledPlugin
    public let argv: [String]
    public let context: CmuxPluginInvocationContext
    public let paths: CmuxPluginPaths

    public init(
        plugin: CmuxInstalledPlugin,
        argv: [String],
        context: CmuxPluginInvocationContext,
        paths: CmuxPluginPaths
    ) {
        self.plugin = plugin
        self.argv = argv
        self.context = context
        self.paths = paths
    }

    /// `argv[0]` containing a slash but not starting with one is relative to
    /// the plugin directory; a bare name is looked up on `PATH`.
    public var resolvedArgv: [String] {
        guard let first = argv.first, first.contains("/"), !first.hasPrefix("/") else { return argv }
        let resolved = plugin.directory.appendingPathComponent(first).standardizedFileURL.path
        return [resolved] + argv.dropFirst()
    }

    /// Environment variables handed to the plugin. Names that cmux already
    /// sets in its terminals (`CMUX_SOCKET_PATH`, `CMUX_WORKSPACE_ID`,
    /// `CMUX_SURFACE_ID`, `CMUX_BUNDLED_CLI_PATH`) keep their meaning.
    public var environment: [String: String] {
        let name = plugin.name
        var environment: [String: String] = [
            "CMUX_PLUGIN_ID": name,
            "CMUX_PLUGIN_DIR": plugin.directory.path,
            "CMUX_PLUGIN_STATE_DIR": paths.stateDirectory(for: name).path,
            "CMUX_PLUGIN_CONFIG_DIR": paths.configDirectory(for: name).path,
        ]
        environment["CMUX_PLUGIN_VERSION"] = plugin.manifest.version
        environment["CMUX_PLUGIN_ACTION_ID"] = context.actionID
        environment["CMUX_SOCKET_PATH"] = context.socketPath
        environment["CMUX_BUNDLED_CLI_PATH"] = context.cliPath
        environment["CMUX_WORKSPACE_ID"] = context.workspaceID
        environment["CMUX_SURFACE_ID"] = context.surfaceID
        for key in ["CMUX_PLUGIN_VERSION", "CMUX_PLUGIN_ACTION_ID", "CMUX_SOCKET_PATH", "CMUX_BUNDLED_CLI_PATH", "CMUX_WORKSPACE_ID", "CMUX_SURFACE_ID"] {
            if environment[key] == nil { environment[key] = "" }
        }
        var contextObject: [String: String] = ["plugin_id": name]
        contextObject["action_id"] = context.actionID
        contextObject["workspace_id"] = context.workspaceID
        contextObject["surface_id"] = context.surfaceID
        contextObject["socket_path"] = context.socketPath
        if let data = try? JSONSerialization.data(withJSONObject: contextObject, options: [.sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            environment["CMUX_PLUGIN_CONTEXT_JSON"] = json
        }
        return environment
    }

    /// A self-contained script: exports the environment, prepends the CLI
    /// directory to `PATH`, enters the plugin directory, and `exec`s argv.
    public var shellScript: String {
        var lines = environment
            .sorted { $0.key < $1.key }
            .map { "export \($0.key)=\(Self.shellQuoted($0.value))" }
        if let cliPath = context.cliPath {
            let binDirectory = (cliPath as NSString).deletingLastPathComponent
            lines.append("export PATH=\(Self.shellQuoted(binDirectory)):\"$PATH\"")
        }
        lines.append("/bin/mkdir -p \"$CMUX_PLUGIN_STATE_DIR\" 2>/dev/null")
        lines.append("cd \(Self.shellQuoted(plugin.directory.path)) || exit 1")
        lines.append("exec " + resolvedArgv.map(Self.shellQuoted).joined(separator: " "))
        return lines.joined(separator: "\n")
    }

    public static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
