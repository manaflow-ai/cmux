public import CmuxNextDesign
import CmuxNextCompat
public import Foundation

/// `appearance.themeFile` in cmux-next.json: the theme file whose look applies, by name. A theme file
/// is `~/.config/cmux/themes/<name>.json` (beside cmux-next.json): a partial overlay of the look
/// settings (`ThemeFileOverlay`), so a person rices the whole app from a dotfile with no build.
/// Unset (the default) applies none, so nothing changes until a person picks one.
public nonisolated struct ThemeFileSetting: Sendable {
    /// The folder beside cmux-next.json that holds the theme files.
    public static let folderName = "themes"
    public static let fileExtension = "json"
    /// A theme file larger than this is refused unread: a look is a few hundred bytes.
    public static let maximumBytes = 256 * 1024

    public init() {}

    /// Whether `name` can name a theme file: a plain file name with no `/`, no leading dot, no
    /// surrounding spaces or control characters, and no `.json` (the setting holds the bare name).
    public static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 200 && name == name.trimmingCharacters(in: .whitespaces)
            && !name.hasPrefix(".") && !name.contains("/") && !name.contains(":")
            && !name.lowercased().hasSuffix(".\(fileExtension)")
            && !name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    /// `<config directory>/themes`.
    public static func folder(configDirectory: URL) -> URL {
        configDirectory.appending(path: folderName, directoryHint: .isDirectory)
    }

    /// `<config directory>/themes/<name>.json`.
    public static func url(named name: String, configDirectory: URL) -> URL {
        folder(configDirectory: configDirectory).appending(path: "\(name).\(fileExtension)", directoryHint: .notDirectory)
    }

    /// The theme file `root` names, nil when unset or not a valid name (the schema check reports it).
    public static func name(in root: JSONValue) -> String? {
        guard let name = root.value(at: configPath)?.stringValue, isValidName(name) else { return nil }
        return name
    }

    /// The names of the theme files in the folder, sorted as Finder sorts them. File I/O.
    public static func names(configDirectory: URL) -> [String] {
        let folder = folder(configDirectory: configDirectory)
        let files = (try? FileManager.checked.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension.lowercased() == fileExtension }
            .map { $0.deletingPathExtension().lastPathComponent }
            .filter(isValidName)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

extension SettingsController {
    /// What Settings lists as problems: every diagnostic but the notes saying which keys the theme
    /// file sets, which are no problem (a working theme file shows no warning).
    public var pageDiagnostics: [SettingsDiagnostic] { diagnostics.filter { $0.kind != .setByThemeFile } }

    /// A palette row's values: for `appearance.themeFile` None and every file in the themes folder
    /// (as the last load read it, so hovering one previews it with no disk read); for any other
    /// setting its kind's values (`SettingDescriptor.paletteOptions`).
    public func paletteOptions(_ descriptor: SettingDescriptor, current: JSONValue?, themeColors: [ThemeRGB]) -> [SettingOption] {
        guard descriptor.path == ThemeFileSetting.configPath else { return descriptor.paletteOptions(current: current, themeColors: themeColors) }
        let names = themeFileSources.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return [SettingOption(value: nil, title: descriptor.defaultLabel ?? "", isCurrent: current == nil)]
            + names.map { SettingOption(value: .string($0), title: $0, isCurrent: current?.stringValue == $0) }
    }

    /// `value` with each entry the active theme file supplies to `descriptor`'s object (its
    /// `appearance.themeEdits` colors) put back to the person's own: their entry when their file has
    /// one, else none. An entry the person changed is theirs and stays.
    func strippingThemeFileEntries(_ descriptor: SettingDescriptor, _ value: JSONValue?) -> JSONValue? {
        guard case .object(var members)? = value,
              let added = themeFile?.values.first(where: { $0.path == descriptor.path })?.value.objectValue else { return value }
        let own = fileRoot.value(at: descriptor.path)?.objectValue ?? [:]
        for (key, entry) in added where members[key] == entry && own[key] != entry { members[key] = own[key] }
        return .object(members)
    }
}
