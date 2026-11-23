import CmuxNextCompat
public import Foundation

/// The settings that belong to this build, not to the Mac account: the cmux tools answer
/// (`agents.cmuxMcp*`) and every Computer Use permission (`computerUse.*`). The rule lives in Rust,
/// cmux-config `build_scope` (which keys, the first read's copy from the shared file, where the
/// settings owner writes them); this only reads the build's file over the document the app parsed,
/// as every Rust reader does, so the app shows and applies the same values its daemon and agents
/// use. NIGHTLY and Release share `~/.config/cmux/cmux-next.json`, so without it one build's grant
/// or answer applied to the other.
public nonisolated struct BuildScopedSettings {
    public nonisolated init() {}
    /// cmux-config `build_scope::BUILD_SETTINGS_ENV` (``BuildStatePaths/buildSettingsFileKey``).
    public static let fileKey = "CMUX_NEXT_BUILD_SETTINGS_FILE"

    /// cmux-config `build_scope::SCOPED_PATHS`.
    static let paths: [[String]] = [["agents", "cmuxMcp"], ["agents", "cmuxMcpClaude"], ["agents", "cmuxMcpCodex"], ["computerUse"]]

    /// This launch's build file: the variable, only while the settings file is the shared one
    /// (`CmuxConfigFile.overrideKey` unset or naming the shared file), as `build_scope::build_file`.
    public static func file(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL? {
        guard let path = environment[fileKey], path.hasPrefix("/") else { return nil }
        if let override = environment[CmuxConfigFile.overrideKey], !override.isEmpty,
           CmuxConfigFile.defaultURL(home: home, environment: environment).standardizedFileURL
            != CmuxConfigFile.defaultURL(home: home, environment: [:]).standardizedFileURL {
            return nil
        }
        return URL(fileURLWithPath: path)
    }

    /// `root` (the shared file's document) with the build's values in place of its own. No build
    /// file, or one not written yet (the daemon writes it from the shared values on its first read),
    /// leaves `root` as it is.
    public static func overlay(_ root: JSONValue, buildFile: URL? = file()) -> JSONValue {
        overlay(root, buildText: text(of: buildFile))
    }

    /// The build file's text, nil without one.
    public static func text(of buildFile: URL?) -> String? {
        buildFile.flatMap { try? String(blockingContentsOf: $0, encoding: .utf8) }
    }

    /// ``overlay(_:buildFile:)`` with the build file's text already read (nil: none).
    public static func overlay(_ root: JSONValue, buildText: String?) -> JSONValue {
        guard let buildText, case .object(var members) = root,
              let values = try? JSONC.parse(buildText), case .object = values else { return root }
        for key in members.keys where isScoped(key) { members.removeValue(forKey: key) }
        if case .object(var agents) = members["agents"] {
            for path in paths where path.first == "agents" { agents.removeValue(forKey: path[1]) }
            members["agents"] = .object(agents)
        }
        var merged = JSONValue.object(members)
        for path in paths {
            if let value = values.value(at: path) { merged = merged.setting(value, at: path) }
        }
        return merged
    }

    /// Whether the top-level member `key` is a build-scoped one (`computerUse`, a flat
    /// `computerUse.mode` or `agents.cmuxMcp`).
    static func isScoped(_ key: String) -> Bool {
        paths.contains { path in
            let dotted = path.joined(separator: ".")
            return key == dotted || key.hasPrefix(dotted + ".")
        }
    }
}
