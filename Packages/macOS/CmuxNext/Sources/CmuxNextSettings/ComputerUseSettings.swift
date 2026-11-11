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

    /// The modes of earlier Computer Use development builds, read as the nearest mode today, so a
    /// file written by one shows no invalid-value warning: `standard` and `unrestricted` asked no
    /// questions (full access), `bounded` kept a grown list of apps (approved apps), `ask` asked.
    public init?(earlierBuildValue value: String) {
        switch value {
        case "standard", "unrestricted": self = .fullAccess
        case "bounded": self = .approvedApps
        case "ask": self = .askEveryTime
        default: return nil
        }
    }
}

/// Whether agents may open a background app's menus (`computerUse.menus`). The raw values are the
/// cmux Computer Use engine's (`cmux_computer_use::menus::MenuMode`).
public nonisolated enum ComputerUseMenus: String, Sendable, Hashable, CaseIterable {
    /// Pop-up and context menus of background apps open so an agent can choose an item (the default,
    /// as Codex Computer Use does); the person's typing stays in their app while one is open.
    case open
    /// Nothing that opens a menu runs in the background.
    case refuse
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
/// - `menus` (`open`): agents may open pop-up and context menus of background apps to choose an
///   item; `refuse` keeps every menu closed. Menu bar menus never open in the background.
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
    public static let menusPath = ["computerUse", "menus"]
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
    public var menus: ComputerUseMenus = .open
    public init() {}

    static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> Self {
        var settings = Self()
        guard var reader = ConfigFieldReader(root, at: ["computerUse"], diagnostics: &diagnostics) else { return settings }
        if let raw = reader.members["mode"]?.stringValue, let earlier = ComputerUseMode(earlierBuildValue: raw) {
            settings.mode = earlier
        } else if let value = reader.choice("mode", ComputerUseMode.self) {
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
        if let value = reader.choice("menus", ComputerUseMenus.self) { settings.menus = value }
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
                                  showCursor: showCursor, cloudVm: false, menus: menus.rawValue)
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
        let menus: String
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
                                         "What agents may do with the apps on this Mac. Denied apps are never used, in any mode."),
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
                                         "Apps no agent may use, in any mode: an app ID, an ID prefix ending in *, or name: and the app's name."),
                summary: SettingsText.keyed("settings.computerUse.deniedApps.summary", "Apps agents may never use"),
                kind: .stringList, default: .array(ComputerUseSettings.defaultDeniedApps.map(JSONValue.string)),
                keywords: ["computer use", "deny", "block", "apps", "password", "terminal", "exclude"]
            ),
            toggle(ComputerUseSettings.allowOwnMachinesPath,
                   SettingsText.keyed("settings.computerUse.allowOwnMachines", "Allow My Other Machines"),
                   help: SettingsText.keyed("settings.computerUse.allowOwnMachines.help",
                                            "Agents on your other machines, signed in to the same account, may use this Mac's apps."),
                   summary: SettingsText.keyed("settings.computerUse.allowOwnMachines.summary", "Agents on your other machines may use this Mac"),
                   defaults.allowOwnMachines, keywords: ["remote", "machines", "devices", "same account"]),
            toggle(ComputerUseSettings.pauseOnTakeoverPath,
                   SettingsText.keyed("settings.computerUse.pauseOnTakeover", "Pause When I Use the Mouse or Keyboard"),
                   help: SettingsText.keyed("settings.computerUse.pauseOnTakeover.help",
                                            "While you use the mouse or keyboard, agents wait before their next click or key press."),
                   summary: SettingsText.keyed("settings.computerUse.pauseOnTakeover.summary", "Agents wait while you use this Mac"),
                   defaults.pauseOnTakeover, keywords: ["pause", "takeover", "mouse", "keyboard", "interrupt"]),
            toggle(ComputerUseSettings.showCursorPath,
                   SettingsText.keyed("settings.computerUse.showCursor", "Show Agent Cursor"),
                   help: SettingsText.keyed("settings.computerUse.showCursor.help",
                                            "A blue cursor shows wherever an agent clicks or types."),
                   summary: SettingsText.keyed("settings.computerUse.showCursor.summary", "A blue cursor shows where agents act"),
                   defaults.showCursor, keywords: ["cursor", "pointer", "blue", "overlay"]),
            toggle(ComputerUseSettings.livePreviewPath,
                   SettingsText.keyed("settings.computerUse.livePreview", "Live Preview in Chat"),
                   help: SettingsText.keyed("settings.computerUse.livePreview.help",
                                            "While an agent uses an app, its chat shows a small live view of that app. Click the view to open Agent Activity."),
                   summary: SettingsText.keyed("settings.computerUse.livePreview.summary", "Shows the app an agent uses in its chat"),
                   defaults.livePreview, keywords: ["live preview", "preview", "agent activity", "screenshot", "chat"]),
            SettingDescriptor(
                ComputerUseSettings.menusPath, section: .general, group: group,
                title: SettingsText.keyed("settings.computerUse.menus", "Menus in Background Apps"),
                help: SettingsText.keyed("settings.computerUse.menus.help",
                                         "Agents may open pop-up and context menus of apps in the background to choose an item. Menu bar menus never open in the background."),
                summary: SettingsText.keyed("settings.computerUse.menus.summary", "Agents may open menus in background apps"),
                kind: .choice([
                    SettingChoice(ComputerUseMenus.open.rawValue, SettingsText.keyed("settings.computerUse.menus.open", "Open Menus")),
                    SettingChoice(ComputerUseMenus.refuse.rawValue, SettingsText.keyed("settings.computerUse.menus.refuse", "Never Open Menus")),
                ]),
                default: .string(defaults.menus.rawValue),
                keywords: ["computer use", "menu", "pop-up", "popup", "context menu", "right click", "background"]
            ),
            toggle(ComputerUseSettings.allowForegroundPath,
                   SettingsText.keyed("settings.computerUse.allowForeground", "Allow Foreground Input"),
                   help: SettingsText.keyed("settings.computerUse.allowForeground.help",
                                            "Advanced. Agents may bring an app to the front and move your pointer when it takes no background input."),
                   summary: SettingsText.keyed("settings.computerUse.allowForeground.summary", "Advanced: agents may take focus and move the pointer"),
                   defaults.allowForeground, keywords: ["foreground", "focus", "pointer", "advanced", "background"]),
        ]
    }
}
