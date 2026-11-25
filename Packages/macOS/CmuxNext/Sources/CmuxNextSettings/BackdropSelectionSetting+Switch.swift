public import Foundation
public import CmuxNextDesign

/// The automatic backgrounds (schemas/settings/source/appearance.json): Light and Dark
/// (`appearance`, with `appearance.backgroundLight` / `appearance.backgroundDark`), Time of Day
/// (`schedule`, with `appearance.backgroundSchedule`), how a dynamic macOS wallpaper changes
/// (`appearance.backgroundDynamic`) and where the sun is read for (`appearance.backgroundLocation`).
extension BackdropSelectionSetting {
    /// Light and Dark: the light and dark pictures, per window appearance.
    public static let appearanceID = "appearance"
    /// Time of Day: the schedule's picture of now.
    public static let scheduleID = "schedule"

    /// `appearance.backgroundRotation`: a choice string, or a number of minutes (1...1440).
    public static func rotation(_ value: JSONValue?) -> BackdropRotation? {
        if let text = value?.stringValue { return BackdropRotation(rawValue: text) }
        return value?.doubleValue.flatMap(BackdropRotation.init(minutes:))
    }

    /// `appearance.backgroundDynamic`, its default when unset or unknown.
    public static func dynamicMode(_ root: JSONValue) -> BackdropDynamicMode {
        root.value(at: dynamicPath)?.stringValue.flatMap(BackdropDynamicMode.init(rawValue:)) ?? dynamicDefault
    }

    /// A picture `appearance.backgroundLight`, `appearance.backgroundDark` or a schedule entry may
    /// name: a fixed background (art, `desktop`, `system:`, `file:`), never a shuffle or `none`.
    public static func picture(_ raw: String) -> BackdropSelection? {
        guard !BackdropArt.removedIDs.contains(raw) else { return nil }
        return BackdropSelection(id: raw)
    }

    /// Light and Dark's pictures as one selection; an unset side shows the other's, and with
    /// neither set there is none.
    public static func pair(_ root: JSONValue) -> BackdropSelection? {
        let light = root.value(at: lightPath)?.stringValue.flatMap(picture)
        let dark = root.value(at: darkPath)?.stringValue.flatMap(picture)
        guard let shownLight = light ?? dark else { return nil }
        let shownDark = dark ?? shownLight
        return shownLight == shownDark ? shownLight : .pair(light: shownLight, dark: shownDark)
    }

    /// `appearance.backgroundSchedule` read; nil when unset, empty or any entry is invalid.
    public static func schedule(_ root: JSONValue) -> BackdropTimeOfDay? {
        guard let members = root.value(at: schedulePath)?.objectValue, !members.isEmpty else { return nil }
        var strings: [String: String] = [:]
        for (key, value) in members {
            guard let text = value.stringValue else { return nil }
            strings[key] = text
        }
        return BackdropTimeOfDay.parse(strings) { picture($0) != nil }
    }

    /// Whether a value is valid for `appearance.backgroundLight` or `appearance.backgroundDark`.
    static func acceptsPicture(_ value: JSONValue) -> Bool {
        value.stringValue.flatMap(picture) != nil
    }

    /// Whether a value is valid for `appearance.backgroundSchedule`: an object (empty allowed) of
    /// valid times to fixed backgrounds.
    static func acceptsSchedule(_ value: JSONValue) -> Bool {
        guard let members = value.objectValue else { return false }
        return members.allSatisfy { key, value in
            BackdropTimeOfDay.when(key) != nil && value.stringValue.flatMap(picture) != nil
        }
    }

    /// Whether a value is valid for `appearance.backgroundMemory`, what each background mode last
    /// showed: an object with at most `rotate` (`daily` or a folder), `folder` (a folder) and `off`
    /// (`none` or a fixed picture). The Settings page reads and writes it; the engine never does.
    static func acceptsMemory(_ value: JSONValue) -> Bool {
        guard let members = value.objectValue else { return false }
        return members.allSatisfy { name, value in
            guard let text = value.stringValue else { return false }
            switch name {
            case "rotate": return text == dailyID || folderPath(text) != nil
            case "folder": return folderPath(text) != nil
            case "off": return text == "none" || picture(text) != nil
            default: return false
            }
        }
    }

    /// Whether a value is valid for `appearance.backgroundLocation`: `"LAT,LON"`.
    static func acceptsLocation(_ value: JSONValue) -> Bool {
        value.stringValue.flatMap(BackdropLocation.init(text:)) != nil
    }
}
