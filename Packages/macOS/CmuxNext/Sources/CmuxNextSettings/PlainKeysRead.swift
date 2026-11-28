/// One Rust `snapshot.read` (cmux-tui/crates/cmux-config/src/app_ops/snapshot.rs) for the plain
/// true/false and choice keys of `CmuxConfigSnapshot.parse`: each key's value (the file's when
/// valid, else the schema default) and its diagnostic in Swift's wording, from the schema's kinds,
/// defaults and choices, so no Swift `XxxSetting.parse(root)` per key (RFD #57174, step B).
nonisolated struct PlainKeysRead {
    let values: [String: JSONValue]
    let diagnostics: [SettingsDiagnostic]

    /// Reads `paths` from `root`; an absent key is its default with no diagnostic.
    init(_ root: JSONValue, _ paths: [[String]]) {
        let keys = JSONValue.array(paths.map { .string($0.joined(separator: ".")) })
        let reply = SettingsRust.answer("snapshot.read", ["root": root.keeping(paths), "keys": keys])
        values = reply["values"]?.objectValue ?? [:]
        diagnostics = (reply["diagnostics"]?.arrayValue ?? []).compactMap { item in
            guard let path = item["path"]?.stringValue, let message = item["message"]?.stringValue else { return nil }
            return SettingsDiagnostic(kind: .invalidValue, path: path, message: message)
        }
    }

    func bool(_ path: [String], _ fallback: Bool) -> Bool {
        values[path.joined(separator: ".")]?.boolValue ?? fallback
    }

    func choice<Choice: RawRepresentable>(_ path: [String], _ fallback: Choice) -> Choice where Choice.RawValue == String {
        values[path.joined(separator: ".")]?.stringValue.flatMap(Choice.init(rawValue:)) ?? fallback
    }
}

extension CmuxConfigSnapshot {
    /// The Labs, Home, tab and window toggles and choices, read in one `snapshot.read`.
    mutating func takePlainKeys(_ root: JSONValue) {
        let toggles: [([String], WritableKeyPath<CmuxConfigSnapshot, Bool>, Bool)] = [
            (Self.previewFeaturesPath, \.previewFeatures, Self.previewFeaturesDefault),
            (Self.appStorePath, \.appStore, Self.appStoreDefault),
            (Self.liveTreePath, \.liveTree, Self.liveTreeDefault),
            (Self.voiceRoomPath, \.voiceRoom, Self.voiceRoomDefault),
            (Self.machineJoinPath, \.machineJoin, Self.machineJoinDefault),
            (Self.liveCodePath, \.liveCode, Self.liveCodeDefault),
            (Self.pauseAgentMachinesPath, \.pauseAgentMachines, Self.pauseAgentMachinesDefault),
            (Self.customizeFromTheAppPath, \.customizeFromTheApp, Self.customizeFromTheAppDefault),
            (Self.customizeDoctorNoticePath, \.customizeDoctorNotice, Self.customizeDoctorNoticeDefault),
            (Self.agentCustomizationPath, \.agentCustomization, Self.agentCustomizationDefault),
            (Self.teamComputePath, \.teamCompute, Self.teamComputeDefault),
            (Self.commentThreadsPath, \.commentThreads, Self.commentThreadsDefault),
            (Self.hostsSidebarPath, \.hostsSidebar, Self.hostsSidebarDefault),
            (HomeChannelsSetting.configPath, \.homeChannelsEnabled, HomeChannelsSetting.fallback),
            (HomeFeedRowsSetting.configPath, \.homeFeedInChief, HomeFeedRowsSetting.fallback),
            (HomeChiefPetSetting.configPath, \.homeChiefPetEnabled, HomeChiefPetSetting.fallback),
            (ChiefDockSetting.sidePanelPath, \.chiefDockSidePanel, ChiefDockSetting.sidePanelDefault),
            (ChiefDockSetting.openBesidePath, \.chiefDockOpenBeside, ChiefDockSetting.openBesideDefault),
            (HomeClipboardHistorySetting.configPath, \.homeClipboardHistory, HomeClipboardHistorySetting.fallback),
            (NewTerminalWorkspaceSetting.configPath, \.newTerminalOpensWorkspace, NewTerminalWorkspaceSetting.fallback),
            (SwapCmdTAndCmdNSetting.configPath, \.swapCmdTAndCmdN, SwapCmdTAndCmdNSetting.fallback),
        ]
        let choices = [WindowTitlebarSetting.configPath, TitlebarButtonsSetting.configPath, PlusButtonSetting.configPath,
                       PaneBackgroundsSetting.configPath, CommandDigitsSetting.configPath, TasksLayoutSetting.layoutPath]
        let plain = PlainKeysRead(root, toggles.map(\.0) + choices)
        for (path, keyPath, fallback) in toggles { self[keyPath: keyPath] = plain.bool(path, fallback) }
        titlebar = plain.choice(WindowTitlebarSetting.configPath, WindowTitlebarSetting.fallback)
        titlebarButtons = plain.choice(TitlebarButtonsSetting.configPath, TitlebarButtonsSetting.fallback)
        plusButton = plain.choice(PlusButtonSetting.configPath, PlusButtonSetting.fallback)
        paneBackgrounds = plain.choice(PaneBackgroundsSetting.configPath, PaneBackgroundsSetting.fallback)
        commandDigits = plain.choice(CommandDigitsSetting.configPath, CommandDigitsSetting.fallback)
        tasksLayout = plain.choice(TasksLayoutSetting.layoutPath, TasksLayoutSetting.layoutDefault)
        diagnostics += plain.diagnostics
    }
}
