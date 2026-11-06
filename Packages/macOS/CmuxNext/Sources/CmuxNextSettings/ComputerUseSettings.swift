public import Foundation

/// How much agents may do with the apps on this Mac (`computerUse.mode`). The raw values are the
/// cmux Computer Use engine's (`cmux_computer_use::policy::Mode`).
public nonisolated enum ComputerUseMode: String, Sendable, Hashable, CaseIterable {
    /// No agent sees or uses any app.
    case off
    /// Screenshots and reading app contents; no clicks or typing.
    case lookOnly
    /// Asks once per app in each agent session.
    case askEveryTime
    /// Asks the first time each app is used and remembers the answer.
    case approvedApps
    /// Any app except the denied ones, without asking (the default).
    case fullAccess
}

/// Which Computer Use driver ran before cmux Computer Use (`computerUse.driver`, retired).
/// Kept only so the old helper paths still compile until they are removed; nothing reads it
/// from cmux.json any more.
public nonisolated enum ComputerUseDriver: String, Sendable, Hashable, CaseIterable {
    case legacy
    case upstream
}

/// `computerUse.*` in cmux.json: what agents may do with the apps on this Mac through cmux
/// Computer Use, which is built in (no helper to install).
///
/// - `mode` (`fullAccess` by default): off, look only, ask every time, approved apps or full access.
/// - `deniedApps`: apps no agent may use in any mode. Each entry is an app id (`com.apple.Terminal`),
///   an id prefix (`com.1password.*`) or `name:App Name`. The default is the engine's list
///   (password managers, System Settings, terminals, cmux itself); the person may remove entries.
/// - `allowOwnMachines` (on): agents on the person's other machines (same account) may use this one.
/// - `pauseOnTakeover` (on): agents pause while the person uses the mouse or keyboard.
/// - `showCursor` (on): the blue agent cursor shows where an agent acts.
/// - `allowForeground` (off): agents may send input that takes focus or moves the real pointer.
/// - `livePreview` (on): a chat shows a small live view of the app its agent uses.
///
/// `computerUse.enabled` and `computerUse.driver` are retired. An old file's
/// `"enabled": false` still turns Computer Use off (mode `off`) until the person picks a mode
/// (``RenamedSettingKeys``: a write of `computerUse.mode` removes the old key).
public nonisolated struct ComputerUseSettings: Sendable, Equatable {
    public static let modePath = ["computerUse", "mode"]
    public static let deniedAppsPath = ["computerUse", "deniedApps"]
    public static let allowOwnMachinesPath = ["computerUse", "allowOwnMachines"]
    public static let pauseOnTakeoverPath = ["computerUse", "pauseOnTakeover"]
    public static let allowForegroundPath = ["computerUse", "allowForeground"]
    public static let showCursorPath = ["computerUse", "showCursor"]
    public static let livePreviewPath = ["computerUse", "livePreview"]
    /// Retired keys (`schemas/settings/retired-keys.json`); `enabledPath` is read once as the
    /// legacy value of `modePath`.
    public static let enabledPath = ["computerUse", "enabled"]
    public static let driverPath = ["computerUse", "driver"]

    /// The engine's default deny list, entry for entry
    /// (`cmux-tui/crates/cmux-computer-use/src/policy.rs`, `default_denied_apps`;
    /// `ComputerUseSettingsTests` compares the two).
    public static let defaultDeniedApps: [String] = [
        // Password managers and keychains.
        "com.apple.keychainaccess", "com.apple.Passwords", "com.1password.*", "com.agilebits.onepassword*",
        "com.bitwarden.*", "com.dashlane.*", "com.lastpass.*", "com.nordpass.*", "me.proton.pass",
        "org.keepassxc.keepassxc", "com.markmcguill.strongbox", "in.sinew.enpass*", "com.keepersecurity.*",
        "1password.exe", "bitwarden.exe", "keepass.exe", "keepassxc.exe", "org.keepassxc.KeePassXC",
        "1password", "bitwarden",
        // Where an agent could change OS security settings.
        "com.apple.systempreferences",
        // Terminals: typing there would run commands outside the agent's own sandbox and prompts.
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "net.kovidgoyal.kitty",
        "com.github.wez.wezterm", "org.alacritty", "dev.warp.*", "windowsterminal.exe", "cmd.exe",
        "powershell.exe", "pwsh.exe", "org.gnome.Terminal", "org.gnome.Ptyxis", "org.kde.konsole",
        // cmux itself (an agent driving cmux could approve its own requests).
        "com.cmuxterm.app", "com.cmuxterm.app.*",
    ]

    public var mode: ComputerUseMode = .fullAccess
    public var deniedApps: [String] = Self.defaultDeniedApps
    public var allowOwnMachines = true
    public var pauseOnTakeover = true
    public var allowForeground = false
    public var showCursor = true
    public var livePreview = true
    /// Transitional, for the old helper paths only: always `.upstream`, never read from cmux.json.
    public var driver: ComputerUseDriver = .upstream
    /// Transitional: the retired driver key is never the person's choice now.
    public var driverIsSet: Bool { false }

    /// Transitional view of the retired `computerUse.enabled`: on unless the mode is off.
    /// Setting it on keeps a non-off mode, or picks the default (Full access).
    public var enabled: Bool {
        get { mode != .off }
        set { mode = newValue ? (mode == .off ? .fullAccess : mode) : .off }
    }

    public init() {}

    static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> Self {
        var settings = Self()
        guard var reader = ConfigFieldReader(root, at: ["computerUse"], diagnostics: &diagnostics) else { return settings }
        if let value = reader.choice("mode", ComputerUseMode.self) {
            settings.mode = value
        } else if reader.members["mode"] == nil, reader.members["enabled"]?.boolValue == false {
            // The retired switch: an old file's "enabled": false keeps Computer Use off.
            settings.mode = .off
        }
        if let value = reader.bool("allowOwnMachines") { settings.allowOwnMachines = value }
        if let value = reader.bool("pauseOnTakeover") { settings.pauseOnTakeover = value }
        if let value = reader.bool("allowForeground") { settings.allowForeground = value }
        if let value = reader.bool("showCursor") { settings.showCursor = value }
        if let value = reader.bool("livePreview") { settings.livePreview = value }
        diagnostics = reader.diagnostics
        if let value = root.value(at: deniedAppsPath) {
            if let items = value.arrayValue, items.allSatisfy({ !($0.stringValue ?? "").isEmpty }) {
                var seen = Set<String>()
                settings.deniedApps = items.compactMap(\.stringValue).filter { seen.insert($0).inserted }
            } else {
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: deniedAppsPath.joined(separator: "."),
                                                      message: "expected a list of app ids"))
            }
        }
        return settings
    }

    /// The legacy value of `computerUse.mode` an old file's `computerUse.enabled` stands for:
    /// `false` is `"off"`; `true` (or anything else) is no choice, so the default applies.
    static func legacyMode(_ enabled: JSONValue) -> JSONValue? {
        enabled.boolValue == false ? .string(ComputerUseMode.off.rawValue) : nil
    }

    /// The engine's `PolicyConfig` JSON (camelCase keys) for this Mac: never a cloud VM.
    public func policyConfigJSON() -> Data {
        let config = PolicyConfig(mode: mode.rawValue, deniedApps: deniedApps, allowOwnMachines: allowOwnMachines,
                                  pauseOnTakeover: pauseOnTakeover, allowForeground: allowForeground,
                                  showCursor: showCursor, cloudVm: false)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // A struct of strings and booleans always encodes; an empty object is the engine's default.
        return (try? encoder.encode(config)) ?? Data("{}".utf8)
    }

    private struct PolicyConfig: Encodable {
        let mode: String
        let deniedApps: [String]
        let allowOwnMachines: Bool
        let pauseOnTakeover: Bool
        let allowForeground: Bool
        let showCursor: Bool
        let cloudVm: Bool
    }
}

/// The Computer Use rows (Settings > Computer Use; the page's Computer Use card draws them).
nonisolated enum ComputerUseSettingsSchema {
    static var descriptors: [SettingDescriptor] {
        let group = SettingsText.keyed("settings.group.computerUse", "Computer Use")
        let defaults = ComputerUseSettings()
        func toggle(_ path: [String], _ title: SettingText, help: SettingText, summary: SettingText, _ value: Bool,
                    keywords: [String]) -> SettingDescriptor {
            SettingDescriptor(path, section: .general, group: group, title: title, help: help, summary: summary,
                              kind: .toggle, default: .bool(value), keywords: ["computer use"] + keywords)
        }
        return [
            SettingDescriptor(
                ComputerUseSettings.modePath, section: .general, group: group,
                title: SettingsText.keyed("settings.computerUse.mode", "Computer Use"),
                help: SettingsText.keyed("settings.computerUse.mode.help",
                                         "What agents may do with the apps on this Mac. Full access: any app except denied ones. Approved apps: asks the first time each app is used, and remembers. Ask every time: asks once per app in each agent session. Look only: screenshots and reading, no clicks or typing. Off: agents cannot see or use your apps."),
                summary: SettingsText.keyed("settings.computerUse.mode.summary", "What agents may do with your apps"),
                kind: .choice([
                    SettingChoice(ComputerUseMode.fullAccess.rawValue, SettingsText.keyed("settings.computerUse.mode.fullAccess", "Full Access")),
                    SettingChoice(ComputerUseMode.approvedApps.rawValue, SettingsText.keyed("settings.computerUse.mode.approvedApps", "Approved Apps")),
                    SettingChoice(ComputerUseMode.askEveryTime.rawValue, SettingsText.keyed("settings.computerUse.mode.askEveryTime", "Ask Every Time")),
                    SettingChoice(ComputerUseMode.lookOnly.rawValue, SettingsText.keyed("settings.computerUse.mode.lookOnly", "Look Only")),
                    SettingChoice(ComputerUseMode.off.rawValue, SettingsText.keyed("settings.computerUse.mode.off", "Off")),
                ]),
                default: .string(defaults.mode.rawValue),
                keywords: ["computer use", "agents", "automation", "apps", "access", "permission", "look only", "approve"]
            ),
            SettingDescriptor(
                ComputerUseSettings.deniedAppsPath, section: .general, group: group,
                title: SettingsText.keyed("settings.computerUse.deniedApps", "Denied Apps"),
                help: SettingsText.keyed("settings.computerUse.deniedApps.help",
                                         "Apps no agent may use, in any mode. Each entry is an app ID (com.apple.Terminal), an ID prefix ending in * (com.1password.*) or name: and the app's name. The defaults cover password managers, System Settings, terminals and cmux itself; you can remove any of them."),
                summary: SettingsText.keyed("settings.computerUse.deniedApps.summary", "Apps agents may never use"),
                kind: .stringList, default: .array(ComputerUseSettings.defaultDeniedApps.map(JSONValue.string)),
                keywords: ["computer use", "deny", "block", "apps", "password", "terminal", "exclude"]
            ),
            toggle(ComputerUseSettings.allowOwnMachinesPath,
                   SettingsText.keyed("settings.computerUse.allowOwnMachines", "Allow My Other Machines"),
                   help: SettingsText.keyed("settings.computerUse.allowOwnMachines.help",
                                            "Agents running on your other machines, signed in to the same account, may use this Mac's apps under the same mode and denied apps."),
                   summary: SettingsText.keyed("settings.computerUse.allowOwnMachines.summary", "Agents on your other machines may use this Mac"),
                   defaults.allowOwnMachines, keywords: ["remote", "machines", "devices", "same account"]),
            toggle(ComputerUseSettings.pauseOnTakeoverPath,
                   SettingsText.keyed("settings.computerUse.pauseOnTakeover", "Pause When I Use the Mouse or Keyboard"),
                   help: SettingsText.keyed("settings.computerUse.pauseOnTakeover.help",
                                            "While you move the mouse or type, agents wait before their next click or key press, so they never act under your hands."),
                   summary: SettingsText.keyed("settings.computerUse.pauseOnTakeover.summary", "Agents wait while you use this Mac"),
                   defaults.pauseOnTakeover, keywords: ["pause", "takeover", "mouse", "keyboard", "interrupt"]),
            toggle(ComputerUseSettings.showCursorPath,
                   SettingsText.keyed("settings.computerUse.showCursor", "Show Agent Cursor"),
                   help: SettingsText.keyed("settings.computerUse.showCursor.help",
                                            "A blue cursor shows wherever an agent clicks or types, apart from your own pointer."),
                   summary: SettingsText.keyed("settings.computerUse.showCursor.summary", "A blue cursor shows where agents act"),
                   defaults.showCursor, keywords: ["cursor", "pointer", "blue", "overlay"]),
            toggle(ComputerUseSettings.livePreviewPath,
                   SettingsText.keyed("settings.computerUse.livePreview", "Live Preview in Chat"),
                   help: SettingsText.keyed("settings.computerUse.livePreview.help",
                                            "While an agent uses an app, its chat shows a small live view of that app. Click the view to open Agent Activity."),
                   summary: SettingsText.keyed("settings.computerUse.livePreview.summary", "Shows the app an agent uses in its chat"),
                   defaults.livePreview, keywords: ["live preview", "preview", "agent activity", "screenshot", "chat"]),
            toggle(ComputerUseSettings.allowForegroundPath,
                   SettingsText.keyed("settings.computerUse.allowForeground", "Allow Foreground Input"),
                   help: SettingsText.keyed("settings.computerUse.allowForeground.help",
                                            "Advanced. Agents may bring an app to the front and move your real pointer when an app does not take input in the background. Off, agents act only in the background."),
                   summary: SettingsText.keyed("settings.computerUse.allowForeground.summary", "Advanced: agents may take focus and move the pointer"),
                   defaults.allowForeground, keywords: ["foreground", "focus", "pointer", "advanced", "background"]),
        ]
    }
}
