public import CmuxNextDesignTokens

/// `appearance.machineColors` in cmux.json: the color of a machine's marks (its sidebar rows and
/// tab badges), keyed by the machine's name as cmux shows it, in any case and with any surrounding
/// space: `{"big-red": "#d0453a", "build-mac": "cyan"}`. A value is `#RRGGBB`, or one of the
/// accents MachineColor picks from (red, green, yellow, purple, cyan, orange, pink, blue), which
/// follows the theme. A machine with no entry keeps its automatic color (MachineColor). The
/// Machines card in Settings writes one entry per machine.
public nonisolated struct MachineColorsSetting: Sendable {
    public let configPath = ["appearance", "machineColors"]

    public init() {}

    /// The picks in `root`. A bad entry is dropped with a diagnostic at its key; the others still apply.
    public func parse(_ root: JSONValue) -> (MachineColorOverrides, [SettingsDiagnostic]) {
        guard let value = root.value(at: configPath) else { return (.none, []) }
        let path = configPath.joined(separator: ".")
        guard case .object(let entries) = value else {
            return (.none, [SettingsDiagnostic(kind: .invalidValue, path: path, message: "expected an object")])
        }
        var colors: [String: String] = [:]
        var diagnostics: [SettingsDiagnostic] = []
        for (name, entry) in entries.sorted(by: { $0.key < $1.key }) {
            guard !MachineColor(name: name).key.isEmpty, let color = entry.stringValue, MachineColorOverrides.pick(color) != nil else {
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: "\(path).\(name)",
                                                      message: "expected a machine name with \"#RRGGBB\" or red, green, yellow, purple, cyan, orange, pink or blue"))
                continue
            }
            colors[name] = color
        }
        return (MachineColorOverrides(colors), diagnostics)
    }

    /// The row: drawn by the Machines card (a color per machine), not as a map editor.
    static var descriptor: SettingDescriptor {
        SettingDescriptor(
            ["appearance", "machineColors"], section: .machines,
            group: SettingsText.keyed("settings.group.machineColors", "Machine Colors"),
            title: SettingsText.keyed("settings.machines.colors", "Machine Color"),
            help: SettingsText.keyed("settings.machines.colors.help",
                                     "The color of each machine's sidebar rows and tab badges, by machine name: \"#RRGGBB\", or an accent name (red, green, yellow, purple, cyan, orange, pink, blue) that follows the theme. A machine without one gets a color from its name."),
            kind: .stringMap, default: .object([:]),
            keywords: ["machine", "computer", "server", "ssh", "cloud", "color", "colour", "identity"]
        )
    }
}

extension CmuxConfigSnapshot {
    /// `appearance.machineColors`: the colors people picked for machines; none when unset. Read
    /// from the root (its diagnostics join the snapshot's when it is parsed).
    public var machineColors: MachineColorOverrides { MachineColorsSetting().parse(root).0 }
}
