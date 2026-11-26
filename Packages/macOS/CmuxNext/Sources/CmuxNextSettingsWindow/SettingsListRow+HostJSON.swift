public import AppKit
public import CmuxNextDesign
public import CmuxNextSettings

/// A list row as Settings' host lists send it (`cmux.settings.host.lists`).
extension SettingsListRow {
    /// One list row; `icon` is its wire icon (the page draws an emoji, or an asset from `icon/<ref>`).
    public var hostJSON: JSONValue {
        ["id": .string(id), "title": .string(title), "subtitle": subtitle.map(JSONValue.string) ?? .null,
         "icon": .string(icon.wire), "active": .bool(isActive)]
    }

    /// A machine's row with its color (`appearance.machineColors`): `color`, the color its marks draw
    /// in now (the person's pick, else the automatic one), and `color_key`, the key its pick is under.
    /// Reading the color observes the store's picks, so the host lists are sent again after a pick.
    @MainActor public var machineHostJSON: JSONValue {
        guard case .object(var members) = hostJSON else { return .null }
        let color = MachineColor(name: title)
        members["color"] = .string(Self.hex(color.color))
        members["color_key"] = .string(color.key)
        return .object(members)
    }

    /// `#RRGGBB` of an opaque color (alpha dropped).
    public static func hex(_ color: NSColor) -> String {
        guard let rgb = color.usingColorSpace(.sRGB) else { return "#808080" }
        let parts = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map { Int(($0 * 255).rounded()) }
        return "#" + parts.map { String(format: "%02X", min(max($0, 0), 255)) }.joined()
    }
}
