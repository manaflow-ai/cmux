import AppKit
import CmuxNextDesign
import CmuxNextSettings
import CmuxNextSettingsWindow

/// What the React Settings page shows beside the schema rows (R82 commit 2): `cmux.settings.host.lists`.
/// Spaces (nil when this daemon has no profiles), saved machines, browser profiles, and the
/// profile color swatches. Edits run catalog actions (`browserProfile.*`) through
/// `cmux.app.action.run`, the same path as the palette and the CLI.
extension SettingsWindowService {
    func pageHostLists() -> JSONValue {
        [
            "rooms": rooms.map { .array($0.map(Self.listRow)) } ?? .null,
            "machines": .array(machines.map(Self.listRow)),
            "browser_profiles": .array(browserProfiles.map { profile in
                [
                    "id": .string(profile.id), "name": .string(profile.name),
                    "color": profile.color.map(JSONValue.string) ?? .null, "icon": profile.icon.map(JSONValue.string) ?? .null,
                    "is_default": .bool(profile.isDefault), "source": profile.source.map(JSONValue.string) ?? .null,
                ]
            }),
            "profile_colors": .array(GroupColor.allCases.map { color in
                ["name": .string(color.rawValue), "swatch": .string(Self.hex(color.swatch)), "fill": .string(Self.hex(color.fill))]
            }),
        ]
    }

    private static func listRow(_ row: SettingsListRow) -> JSONValue {
        ["id": .string(row.id), "title": .string(row.title), "subtitle": row.subtitle.map(JSONValue.string) ?? .null,
         "active": .bool(row.isActive)]
    }

    static func hex(_ color: NSColor) -> String {
        guard let rgb = color.usingColorSpace(.sRGB) else { return "#808080" }
        let parts = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map { Int(($0 * 255).rounded()) }
        return "#" + parts.map { String(format: "%02X", min(max($0, 0), 255)) }.joined()
    }
}
