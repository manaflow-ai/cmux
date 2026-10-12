import Foundation

/// The palette's user aliases and pins in cmux.json (cx-9ce.43):
///
/// ```jsonc
/// "palette": {
///   "aliases": { "vs": "splitRight", "nt": "newTab.default" },
///   "pins": ["newTab.default", "splitRight"]
/// }
/// ```
///
/// An alias is a word that names one command (like a shell alias): typing the whole alias puts
/// that command first. Pinned commands lead the empty palette in this order. A bad entry is
/// dropped.
public nonisolated struct PaletteRankingSetting: Sendable, Hashable {
    public static let aliasesPath = ["palette", "aliases"]
    public static let pinsPath = ["palette", "pins"]

    /// The aliases of each action id, in alias order.
    public var aliases: [String: [String]] = [:]
    /// Pinned action ids, in the user's order, each once.
    public var pins: [String] = []

    /// The setting in `root` (the file's whole JSON).
    public init(_ root: JSONValue) {
        for (alias, value) in (root.value(at: Self.aliasesPath)?.objectValue ?? [:]).sorted(by: { $0.key < $1.key }) {
            let word = alias.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty, let id = value.stringValue, !id.isEmpty else { continue }
            aliases[id, default: []].append(word)
        }
        var seen = Set<String>()
        if case .array(let items) = root.value(at: Self.pinsPath) {
            pins = items.compactMap { $0.stringValue }.filter { !$0.isEmpty && seen.insert($0).inserted }
        }
    }

    /// Raw action ids mean nothing on the Settings page; the user writes them in cmux.json.
    private static let cmuxJSONOnly = "action ids; cmux.json only"

    /// The settings rows, in the palette's Settings group.
    static func descriptors(group: SettingText) -> [SettingDescriptor] {
        [
            SettingDescriptor(
                aliasesPath, section: .general, group: group,
                title: SettingsText.keyed("settings.palette.aliases", "Command Aliases"),
                help: SettingsText.keyed("settings.palette.aliases.help",
                                         "A word that names a command by its action id (\"vs\": \"splitRight\"). Typing the whole word in the command palette puts that command first."),
                kind: .stringMap, default: .object([:]), keywords: ["palette", "alias", "shortcut", "command"]
            )
            .hiddenFromSettingsPage(Self.cmuxJSONOnly),
            SettingDescriptor(
                pinsPath, section: .general, group: group,
                title: SettingsText.keyed("settings.palette.pins", "Pinned Commands"),
                help: SettingsText.keyed("settings.palette.pins.help",
                                         "Commands shown first when the command palette opens, in this order, by action id."),
                kind: .stringList, default: .array([]), keywords: ["palette", "pin", "favorite", "command"]
            )
            .hiddenFromSettingsPage(Self.cmuxJSONOnly),
        ]
    }
}
