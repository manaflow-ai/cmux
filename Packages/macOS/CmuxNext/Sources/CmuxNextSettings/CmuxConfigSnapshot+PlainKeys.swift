/// The plain true/false and choice keys of cmux-next.json, read in one Rust call (`snapshot.read`,
/// cmux-tui/crates/cmux-config/src/app_ops/snapshot.rs): each key's value from the file when it is
/// valid, else the schema default, with Swift's diagnostic wording, plus the retired keys the file
/// still sets. It replaces the one-key Swift `XxxSetting.parse(root)` functions; a key keeps its
/// generated `configPath` and `fallback`, and the fallback is used when Rust gives no value.
nonisolated struct SnapshotPlainKeys: Sendable {
    /// The keys ``CmuxConfigSnapshot/parse(_:validDensities:validMetrics:configDirectory:)`` takes from Rust.
    static let paths: [[String]] = [
        BookmarksBarSetting.configPath, BrowserVimKeysSetting.configPath, BrowserLoadingBarSetting.configPath,
        BrowserImportSetting.configPath, BrowserCookieBannerSetting.configPath, BrowserCookieSyncSetting.configPath,
        HomeChiefBubbleStyleSetting.configPath, BuiltInAdBlockerSetting.configPath, AgentCursorSetting.configPath,
        CmuxConfigSnapshot.previewFeaturesPath, CmuxConfigSnapshot.appStorePath, CmuxConfigSnapshot.liveTreePath,
        CmuxConfigSnapshot.voiceRoomPath, CmuxConfigSnapshot.machineJoinPath, CmuxConfigSnapshot.liveCodePath,
        CmuxConfigSnapshot.pauseAgentMachinesPath, CmuxConfigSnapshot.customizeFromTheAppPath,
        CmuxConfigSnapshot.customizeDoctorNoticePath, CmuxConfigSnapshot.agentCustomizationPath,
        CmuxConfigSnapshot.teamComputePath, CmuxConfigSnapshot.commentThreadsPath, CmuxConfigSnapshot.hostsSidebarPath,
        TerminalTermSetting.configPath, TerminalPredictiveEchoSetting.configPath, AnimationSpeedSetting.configPath,
        PaneAnimationsSetting.configPath, CalmModeSetting.configPath, ReducedBackgroundsSetting.configPath,
        AgentGlowSetting.configPath, PreviousGlassSetting.configPath, LiquidGlassSetting.configPath,
        WindowTitlebarSetting.configPath, TitlebarButtonsSetting.configPath, PlusButtonSetting.configPath,
        PaneBackgroundsSetting.configPath, NewTerminalWorkspaceSetting.configPath, NativeNewTabPageSetting.configPath,
        TabShellIconThemeSetting.configPath, VerticalTabsSetting.configPath, VerticalTabsSetting.expandOnHoverPath,
        LoneChatTabSetting.configPath, SwapCmdTAndCmdNSetting.configPath,
    ]

    /// Choice keys whose diagnostic lists the values bare (`expected one of a, b`).
    static let unquoted = [HomeChiefBubbleStyleSetting.key]

    let values: [String: JSONValue]
    let diagnostics: [String: SettingsDiagnostic]
    let retiredKeys: [String]

    /// Reads ``paths`` from `root`, an object (the caller answers a root that is not one).
    static func read(_ root: JSONValue) -> SnapshotPlainKeys {
        let keys = paths.map { JSONValue.string($0.joined(separator: ".")) }
        let reply = SettingsRust.answer("snapshot.read", [
            "root": root, "keys": .array(keys), "unquoted": .array(unquoted.map(JSONValue.string)),
        ])
        var diagnostics: [String: SettingsDiagnostic] = [:]
        for item in reply["diagnostics"]?.arrayValue ?? [] {
            guard let path = item["path"]?.stringValue, let message = item["message"]?.stringValue else { continue }
            diagnostics[path] = SettingsDiagnostic(kind: .invalidValue, path: path, message: message)
        }
        return SnapshotPlainKeys(values: reply["values"]?.objectValue ?? [:], diagnostics: diagnostics,
                                 retiredKeys: (reply["retiredKeys"]?.arrayValue ?? []).compactMap(\.stringValue))
    }

    /// A true/false key: its value and diagnostic; `fallback` when Rust gave no value.
    func toggle(_ path: [String], fallback: Bool) -> (Bool, SettingsDiagnostic?) {
        let key = path.joined(separator: ".")
        return (values[key]?.boolValue ?? fallback, diagnostics[key])
    }

    /// A choice key: its value and diagnostic; `fallback` when Rust gave no value.
    func choice<Choice: RawRepresentable>(_ path: [String], fallback: Choice) -> (Choice, SettingsDiagnostic?)
    where Choice.RawValue == String {
        let key = path.joined(separator: ".")
        return (values[key]?.stringValue.flatMap(Choice.init(rawValue:)) ?? fallback, diagnostics[key])
    }
}
