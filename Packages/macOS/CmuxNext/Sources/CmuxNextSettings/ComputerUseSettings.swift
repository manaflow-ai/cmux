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
/// - `cursorTag` (`hover`): when an agent cursor shows its tag (the agent's workspace name, or a tag
///   the agent set): while the person's pointer is over it, always, or never.
/// - `settle` (`adaptive`): what the engine waits for after each action before it looks again.
/// - `allowForeground` (off): agents may send input that takes focus or moves the real pointer.
/// - `livePreview` (on): a chat shows a small live view of the app its agent uses.
///
/// `computerUse.enabled` and `computerUse.driver` are retired. An old file's
/// `"enabled": false` still turns Computer Use off (mode `off`) until the person picks a mode
/// (``RenamedSettingKeys``: a write of `computerUse.mode` removes the old key).
public nonisolated struct ComputerUseSettings: Sendable, Equatable {
    // The paths and defaults of the rows are generated from schemas/settings/source/machines.json
    // (SettingsSchema+Machines.generated.swift).
    public static let enabledPath = ["computerUse", "enabled"]
    public static let driverPath = ["computerUse", "driver"]

    /// The engine's default deny list, entry for entry
    /// (`cmux-tui/crates/cmux-computer-use/src/policy.rs`, `default_denied_apps`;
    /// `ComputerUseSettingsTests` compares the two): password managers and keychains, System
    /// Settings, terminals and cmux itself.
    public static var defaultDeniedApps: [String] { deniedAppsDefault }

    public var mode = ComputerUseSettings.modeDefault
    public var deniedApps = ComputerUseSettings.deniedAppsDefault
    public var allowOwnMachines = ComputerUseSettings.allowOwnMachinesDefault
    public var pauseOnTakeover = ComputerUseSettings.pauseOnTakeoverDefault
    public var allowForeground = ComputerUseSettings.allowForegroundDefault
    public var showCursor = ComputerUseSettings.showCursorDefault
    public var cursorTag = ComputerUseSettings.cursorTagDefault
    public var settle = ComputerUseSettings.settleDefault
    public var livePreview = ComputerUseSettings.livePreviewDefault
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
        if let value = reader.choice("cursorTag", ComputerUseCursorTag.self) { settings.cursorTag = value }
        if let value = reader.choice("settle", ComputerUseSettle.self) { settings.settle = value }
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

    /// The engine's `PolicyConfig` JSON (camelCase keys) for this Mac: never a cloud VM. `cursorTag`
    /// is read by cmux Remote's worker for the agent cursor (the engine ignores it).
    public func policyConfigJSON() -> Data {
        let config = PolicyConfig(mode: mode.rawValue, deniedApps: deniedApps, allowOwnMachines: allowOwnMachines,
                                  pauseOnTakeover: pauseOnTakeover, allowForeground: allowForeground,
                                  showCursor: showCursor, cursorTag: cursorTag.rawValue, settle: settle.rawValue, cloudVm: false)
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
        let cursorTag: String
        let settle: String
        let cloudVm: Bool
    }
}
